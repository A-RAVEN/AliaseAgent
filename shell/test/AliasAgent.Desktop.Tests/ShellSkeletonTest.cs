using AliasAgent.Desktop;
using Xunit;
using Xunit.Abstractions;

namespace AliasAgent.Desktop.Tests;

/// <summary>
/// 任务 3.1 的骨架用例：先**故意失败**（证明 dotnet test 真的发现了用例、不是
/// 「0 个测试也退出 0」的假绿），再把断言换成骨架事实让它转绿。
/// </summary>
public class ShellSkeletonTest
{
    private readonly ITestOutputHelper _output;

    public ShellSkeletonTest(ITestOutputHelper output)
    {
        _output = output;
    }

    [Fact]
    public void Skeleton_IsDiscoveredAndTargetsNet10()
    {
        // 可观察：运行时与目标框架都要打印出来（失败时据此归因）。
        _output.WriteLine($"[SKELETON] RuntimeInformation.FrameworkDescription = {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}");
        _output.WriteLine($"[SKELETON] AppContext.TargetFrameworkName        = {AppContext.TargetFrameworkName}");
        _output.WriteLine($"[SKELETON] 壳程序集                                  = {typeof(ShellInfo).Assembly.GetName().Name}");
        _output.WriteLine($"[SKELETON] ShellInfo.TargetFramework                = {ShellInfo.TargetFramework}");
        _output.WriteLine($"[SKELETON] 可执行文件名                             = {ShellInfo.ExecutableName}");

        // 转绿后的断言（骨架事实，不是「永远为真」）：目标框架、程序集名、运行时。
        Assert.Equal("net10.0-windows", ShellInfo.TargetFramework);
        Assert.Equal("AliasAgent.Desktop", typeof(ShellInfo).Assembly.GetName().Name);
        Assert.Contains(".NET 10", System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription);
    }
}
