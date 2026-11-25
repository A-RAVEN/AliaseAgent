using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AliasAgent.Desktop;

/// <summary>
/// 防孤儿：把核心子进程放进一个 Job Object，并设置 `KILL_ON_JOB_CLOSE`
/// （change `windows-desktop-shell` D3 第 5 步 / 任务 4.2）。
///
/// 效果：壳进程无论正常退出还是崩溃，最后一个 Job 句柄一关，**内核**直接终止核心
/// 进程树 —— 不会出现「壳崩了，核心成孤儿继续占着固定端口」。
///
/// 句柄作为**字段**持有（与互斥体一样，防 GC 提前回收把兜底提前触发）。
/// 已知限制：若将来给核心进程设置 breakaway 就会脱离这个 Job，本 change 不设。
/// </summary>
public sealed class JobObject : IDisposable
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x2000;
    private const uint ProcessSetQuota = 0x0100;
    private const uint ProcessTerminate = 0x0001;

    private IntPtr _handle;
    private bool _disposed;

    private JobObject(IntPtr handle)
    {
        _handle = handle;
    }

    /// <summary>
    /// 把进程加入新建的 Job Object。失败返回 null（**不**因此拦住启动：那会变成
    /// 「一个可选兜底失败就起不来」；失败必须写日志说明关联结果）。
    /// </summary>
    public static JobObject? TryAttach(Process process, Action<string> log)
    {
        IntPtr handle = IntPtr.Zero;
        try
        {
            handle = CreateJobObjectW(IntPtr.Zero, null);
            if (handle == IntPtr.Zero)
            {
                log($"[shell] Job Object 创建失败（Win32 错误 {Marshal.GetLastWin32Error()}）：" +
                    "核心不使用 KILL_ON_JOB_CLOSE 兜底");
                return null;
            }

            var info = new JobObjectExtendedLimitInformationNative
            {
                BasicLimitInformation = new JobObjectBasicLimitInformation
                {
                    LimitFlags = JobObjectLimitKillOnJobClose,
                },
            };
            var size = Marshal.SizeOf<JobObjectExtendedLimitInformationNative>();
            var infoPointer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, infoPointer, false);
                if (!SetInformationJobObject(handle, JobObjectExtendedLimitInformation, infoPointer, (uint)size))
                {
                    log($"[shell] Job Object 设置 KILL_ON_JOB_CLOSE 失败（Win32 错误 " +
                        $"{Marshal.GetLastWin32Error()}）：核心不使用该兜底");
                    CloseHandle(handle);
                    return null;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(infoPointer);
            }

            if (!AssignProcessToJobObject(handle, process.Handle))
            {
                log($"[shell] 核心加入 Job Object 失败（pid={process.Id}，Win32 错误 " +
                    $"{Marshal.GetLastWin32Error()}）：核心不使用该兜底");
                CloseHandle(handle);
                return null;
            }

            log($"[shell] 核心已加入 Job Object（pid={process.Id}，KILL_ON_JOB_CLOSE）");
            return new JobObject(handle);
        }
        catch (Exception e)
        {
            log($"[shell] Job Object 关联异常：{e.Message}（核心不使用该兜底）");
            if (handle != IntPtr.Zero) CloseHandle(handle);
            return null;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_handle != IntPtr.Zero)
        {
            CloseHandle(_handle);
            _handle = IntPtr.Zero;
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job, int infoClass, IntPtr info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformationNative
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
}
