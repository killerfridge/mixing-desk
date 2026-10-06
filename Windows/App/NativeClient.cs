using System;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;
namespace MixingDesk;

sealed class NativeClient : IAsyncDisposable
{
    [DllImport("DeskWindows", CallingConvention = CallingConvention.Cdecl)] static extern uint mdw_abi_version();
    [DllImport("DeskWindows", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr mdw_create();
    [DllImport("DeskWindows", CallingConvention = CallingConvention.Cdecl)] static extern void mdw_destroy(IntPtr host);
    [DllImport("DeskWindows", CallingConvention = CallingConvention.Cdecl)] static extern IntPtr mdw_request(IntPtr host, [MarshalAs(UnmanagedType.LPUTF8Str)] string operation, [MarshalAs(UnmanagedType.LPUTF8Str)] string json);
    [DllImport("DeskWindows", CallingConvention = CallingConvention.Cdecl)] static extern void mdw_free(IntPtr response);
    readonly TaskCompletionSource<Dispatcher> ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly Thread thread; IntPtr host; bool disposed;
    public NativeClient()
    {
        thread = new Thread(() =>
        {
            try
            {
                if (mdw_abi_version() != 1)
                    throw new InvalidOperationException("The native audio DLL is incompatible. Reinstall the complete Windows build.");
                host = mdw_create();
                if (host == IntPtr.Zero)
                    throw new InvalidOperationException("Windows audio could not initialize.");
                ready.SetResult(Dispatcher.CurrentDispatcher);
                Dispatcher.Run();
            }
            catch (Exception e) { ready.TrySetException(e); }
            finally { if (host != IntPtr.Zero) { mdw_destroy(host); host = IntPtr.Zero; } }
        })
        {
            IsBackground = true,
            Name = "Mixing Desk control"
        };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }
    public async Task<JsonNode?> Call(string operation, string json = "{}")
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        var dispatcher = await ready.Task;
        return await dispatcher.InvokeAsync(() =>
        {
            var pointer = mdw_request(host, operation, json);
            if (pointer == IntPtr.Zero)
                throw new OutOfMemoryException("Native control request failed.");
            try
            {
                var result = JsonNode.Parse(Marshal.PtrToStringUTF8(pointer)!)!;
                if (!result["ok"]!.GetValue<bool>())
                    throw new InvalidOperationException(result["error"]!.GetValue<string>());
                return result["value"]?.DeepClone();
            }
            finally { mdw_free(pointer); }
        });
    }
    public async ValueTask DisposeAsync()
    {
        if (disposed)
            return;
        disposed = true;
        try
        {
            var dispatcher = await ready.Task;
            await dispatcher.InvokeAsync(() => { mdw_destroy(host); host = IntPtr.Zero; dispatcher.BeginInvokeShutdown(DispatcherPriority.Normal); });
        }
        catch { }
    }
}
