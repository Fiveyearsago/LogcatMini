using Avalonia.Input.Platform;
using Avalonia.Media.Imaging;

namespace LogcatMini.Desktop;

public static class ScreenshotClipboard
{
    // Some backends render clipboard data lazily. Keep the current bitmap alive until replaced.
    static Bitmap? current;
    public static async Task Copy(IClipboard clipboard,byte[] png)
    {
        using var stream=new MemoryStream(png);
        var bitmap=new Bitmap(stream);
        try { await clipboard.SetBitmapAsync(bitmap); }
        catch { bitmap.Dispose();throw; }
        var previous=current;current=bitmap;previous?.Dispose();
        await clipboard.FlushAsync(); // Windows keeps the image available after this app exits.
    }
}
