import Foundation
import Darwin

func runCPUProbeTests() {
    let thread = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, thread) }
    var before: mach_port_urefs_t = 0
    precondition(mach_port_get_refs(mach_task_self_, thread, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before) == KERN_SUCCESS)
    for _ in 0..<100 {
        let cpu = CPUProbe.cpuUsagePercent()
        precondition(cpu.isFinite && cpu >= 0)
    }
    var after: mach_port_urefs_t = 0
    precondition(mach_port_get_refs(mach_task_self_, thread, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after) == KERN_SUCCESS)
    precondition(before == after, "CPU sampling leaked thread send-right references")
    print("PASS: 100 CPU probes keep the current thread's Mach send-right count unchanged")
}
