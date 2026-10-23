// Copyright (c) 2024-2026 YiraSan
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// --- dependencies --- //

const std = @import("std");
const basalt = @import("basalt");

// --- imports --- //

const kernel = @import("root");
const sched = kernel.sched;
const Future = sched.Future;

// --- exports -- //

pub const Domain = @import("Domain.zig");
pub const VirtIrq = @import("VirtIrq.zig");

// --- drivers/intc/root.zig --- //

/// Maximum consecutive interrupts drained on a single domain before ascending/yielding.
const MAX_BATCH_PER_DOMAIN: usize = 16;
/// Hard ceiling on total interrupts processed in a single ISR invocation to bound latency.
const MAX_TOTAL_IRQS: usize = 128;

var root: Domain.New = .{ .null, undefined };

pub fn isRootRegistered() bool {
    return !root.@"0".isNull();
}

pub fn getRoot() !*Domain {
    if (!isRootRegistered()) return error.NoRegisteredRoot;
    return root.@"1".payload();
}

pub fn getRootRef() !Domain.Ref {
    if (!isRootRegistered()) return error.NoRegisteredRoot;
    return Domain.get(root.@"0") orelse error.NoRegisteredRoot;
}

pub fn registerRoot(root_dom: Domain) !void {
    if (isRootRegistered()) return error.AlreadyRegistered;
    root = try Domain.new(root_dom);
}

pub fn handle() !void {
    const root_dom = try getRoot();

    var current_dom: *Domain = root_dom;
    var current_parent: ?VirtIrq.Ref = null;
    var domain_batch: usize = 0;
    var total_handled: usize = 0;

    while (true) {
        const within_budget = (domain_batch < MAX_BATCH_PER_DOMAIN) and (total_handled < MAX_TOTAL_IRQS);

        if (within_budget) {
            if (current_dom.acknowledge()) |virq_ref_const| {
                var virq_ref = virq_ref_const;
                domain_batch += 1;
                total_handled += 1;

                const virq: *VirtIrq = virq_ref.payload();

                virq.nested_in = current_parent;

                if (current_parent) |parent_ref| {
                    _ = parent_ref.payload().pending_children.fetchAdd(1, .acquire);
                }

                switch (virq.kind) {
                    .domain => {
                        var child_dom_ref = Domain.get(virq.content.domain) orelse {
                            std.log.err("intc: VirtIrq (hw={}) references invalid child domain", .{virq.hw_irq});
                            virq.priorityDrop() catch {};
                            virq.deactivate() catch {};
                            virq_ref.release();
                            continue;
                        };
                        const child_dom: *Domain = child_dom_ref.payload();
                        child_dom_ref.release();

                        virq.pending_children.store(1, .release);
                        current_parent = virq_ref;
                        current_dom = child_dom;
                        domain_batch = 0;
                        continue;
                    },

                    .handler => {
                        const h = virq.content.handler;

                        const masked_at_source = if (h.top_half) |top_half|
                            top_half(h.context)
                        else
                            false;

                        virq.priorityDrop() catch |err| {
                            std.log.err("intc: priorityDrop failed on hw_irq {}: {any}", .{ virq.hw_irq, err });
                        };

                        if (masked_at_source) {
                            virq.deactivate() catch |err| {
                                std.log.err("intc: deactivate failed on hw_irq {}: {any}", .{ virq.hw_irq, err });
                            };
                        }

                        if (h.future.isNull()) {
                            if (!masked_at_source) {
                                @panic("unmasked at source interrupt with no future");
                            }
                        } else {
                            // TODO
                        }

                        virq_ref.release();
                        continue;
                    },

                    _ => {
                        std.log.err("intc: unknown VirtIrq kind on hw_irq {}", .{virq.hw_irq});
                        virq.priorityDrop() catch {};
                        virq.deactivate() catch {};
                        virq_ref.release();
                        continue;
                    },
                }
            } else |err| switch (err) {
                Domain.Error.UnregisteredIrq => {
                    domain_batch += 1;
                    continue;
                },
                Domain.Error.SpuriousIrq,
                Domain.Error.RetriggeredIrq,
                Domain.Error.DomainFailure,
                => {},
                else => {},
            }
        }

        if (current_parent) |parent_ref| {
            const parent_virq: *VirtIrq = parent_ref.payload();

            const upper_dom: *Domain = parent_virq.domain.payload();
            const upper_parent: ?VirtIrq.Ref = parent_virq.nested_in;

            parent_virq.priorityDrop() catch |err| {
                std.log.err("intc: parent priorityDrop failed on hw_irq {}: {any}", .{ parent_virq.hw_irq, err });
            };

            VirtIrq.completeParentChain(parent_ref);

            current_dom = upper_dom;
            current_parent = upper_parent;
            domain_batch = 0;
            continue;
        }

        break;
    }
}
