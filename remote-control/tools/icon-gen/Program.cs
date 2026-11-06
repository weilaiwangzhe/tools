using System.Buffers.Binary;
using System.IO.Compression;

var projectRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var output = Path.Combine(projectRoot, "windows-agent", "assets");
Directory.CreateDirectory(output);

var pngs = new[] { 256, 64, 32, 16 }.Select(size => (size, data: RenderPng(size))).ToArray();
File.WriteAllBytes(Path.Combine(projectRoot, "assets", "remote-control-icon.png"), pngs[0].data);
File.WriteAllBytes(Path.Combine(output, "remote-control.ico"), BuildIco(pngs));
Console.WriteLine($"Generated {Path.Combine(output, "remote-control.ico")}");

static byte[] RenderPng(int size)
{
    const int supersample = 4;
    var high = size * supersample;
    var pixels = new Rgba[high * high];

    FillRoundedRect(pixels, high, 8, 8, 240, 240, 52, new Rgba(15, 23, 42, 255));
    StrokeCircle(pixels, high, 128, 128, 93, 4, new Rgba(30, 58, 95, 255));
    FillRoundedRect(pixels, high, 34, 64, 148, 113, 16, new Rgba(231, 247, 255, 255));
    FillRoundedRect(pixels, high, 48, 78, 120, 80, 8, new Rgba(19, 43, 72, 255));
    DrawLine(pixels, high, 91, 190, 125, 190, 9, new Rgba(231, 247, 255, 255));
    DrawLine(pixels, high, 83, 204, 133, 204, 9, new Rgba(231, 247, 255, 255));
    FillRoundedRect(pixels, high, 168, 43, 51, 134, 15, new Rgba(139, 226, 140, 255));
    FillRoundedRect(pixels, high, 176, 56, 35, 91, 8, new Rgba(19, 43, 72, 255));
    FillCircle(pixels, high, 193.5, 161, 5, new Rgba(15, 23, 42, 255));
    DrawLine(pixels, high, 152, 119, 172, 119, 10, new Rgba(55, 214, 195, 255));
    FillCircle(pixels, high, 151, 119, 7, new Rgba(55, 214, 195, 255));
    FillCircle(pixels, high, 173, 119, 7, new Rgba(55, 214, 195, 255));
    FillCircle(pixels, high, 58, 41, 6, new Rgba(55, 214, 195, 255));
    FillCircle(pixels, high, 205, 207, 6, new Rgba(139, 226, 140, 255));

    var result = new Rgba[size * size];
    for (var y = 0; y < size; y++)
    for (var x = 0; x < size; x++)
    {
        var r = 0; var g = 0; var b = 0; var a = 0;
        for (var sy = 0; sy < supersample; sy++)
        for (var sx = 0; sx < supersample; sx++)
        {
            var p = pixels[(y * supersample + sy) * high + x * supersample + sx];
            r += p.R; g += p.G; b += p.B; a += p.A;
        }
        var count = supersample * supersample;
        result[y * size + x] = new Rgba((byte)(r / count), (byte)(g / count), (byte)(b / count), (byte)(a / count));
    }

    using var raw = new MemoryStream();
    for (var y = 0; y < size; y++)
    {
        raw.WriteByte(0);
        for (var x = 0; x < size; x++)
        {
            var p = result[y * size + x];
            raw.WriteByte(p.R); raw.WriteByte(p.G); raw.WriteByte(p.B); raw.WriteByte(p.A);
        }
    }

    using var png = new MemoryStream();
    png.Write(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 });
    WriteChunk(png, "IHDR", BuildIhdr(size));
    using (var compressed = new MemoryStream())
    {
        using (var zlib = new ZLibStream(compressed, CompressionLevel.SmallestSize, leaveOpen: true))
        {
            raw.Position = 0;
            raw.CopyTo(zlib);
        }
        WriteChunk(png, "IDAT", compressed.ToArray());
    }
    WriteChunk(png, "IEND", Array.Empty<byte>());
    return png.ToArray();
}

static byte[] BuildIco((int size, byte[] data)[] images)
{
    using var stream = new MemoryStream();
    using var writer = new BinaryWriter(stream);
    writer.Write((ushort)0); writer.Write((ushort)1); writer.Write((ushort)images.Length);
    var offset = 6 + images.Length * 16;
    foreach (var image in images)
    {
        writer.Write((byte)(image.size == 256 ? 0 : image.size));
        writer.Write((byte)(image.size == 256 ? 0 : image.size));
        writer.Write((byte)0); writer.Write((byte)0);
        writer.Write((ushort)1); writer.Write((ushort)32);
        writer.Write(image.data.Length); writer.Write(offset);
        offset += image.data.Length;
    }
    foreach (var image in images) writer.Write(image.data);
    return stream.ToArray();
}

static byte[] BuildIhdr(int size)
{
    var bytes = new byte[13];
    BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(0, 4), (uint)size);
    BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(4, 4), (uint)size);
    bytes[8] = 8; bytes[9] = 6;
    return bytes;
}

static void WriteChunk(Stream output, string type, byte[] data)
{
    using var writer = new BinaryWriter(output, System.Text.Encoding.ASCII, leaveOpen: true);
    var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
    WriteUInt32(writer, (uint)data.Length); writer.Write(typeBytes); writer.Write(data);
    var crc = Crc32(typeBytes.Concat(data).ToArray()); WriteUInt32(writer, crc);
}

static void WriteUInt32(BinaryWriter writer, uint value)
{
    Span<byte> bytes = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(bytes, value); writer.Write(bytes);
}

static uint Crc32(byte[] bytes)
{
    uint crc = 0xffffffff;
    foreach (var value in bytes)
    {
        crc ^= value;
        for (var bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xedb88320 & (uint)-(int)(crc & 1));
    }
    return ~crc;
}

static void FillRoundedRect(Rgba[] pixels, int width, double x, double y, double w, double h, double radius, Rgba color)
{
    for (var py = 0; py < width; py++)
    for (var px = 0; px < width; px++)
    {
        var xx = px / 4.0;
        var yy = py / 4.0;
        var cx = Math.Clamp(xx, x + radius, x + w - radius);
        var cy = Math.Clamp(yy, y + radius, y + h - radius);
        if ((xx >= x && xx <= x + w && yy >= y && yy <= y + h) && Distance(xx, yy, cx, cy) <= radius) pixels[py * width + px] = color;
    }
}

static void FillCircle(Rgba[] pixels, int width, double cx, double cy, double radius, Rgba color)
{
    for (var py = 0; py < width; py++) for (var px = 0; px < width; px++) if (Distance(px / 4.0, py / 4.0, cx, cy) <= radius) pixels[py * width + px] = color;
}

static void StrokeCircle(Rgba[] pixels, int width, double cx, double cy, double radius, double stroke, Rgba color)
{
    for (var py = 0; py < width; py++) for (var px = 0; px < width; px++) { var d = Distance(px / 4.0, py / 4.0, cx, cy); if (Math.Abs(d - radius) <= stroke / 2) pixels[py * width + px] = color; }
}

static void DrawLine(Rgba[] pixels, int width, double x1, double y1, double x2, double y2, double stroke, Rgba color)
{
    for (var py = 0; py < width; py++) for (var px = 0; px < width; px++) if (PointLineDistance(px / 4.0, py / 4.0, x1, y1, x2, y2) <= stroke / 2) pixels[py * width + px] = color;
}

static double Distance(double x1, double y1, double x2, double y2) => Math.Sqrt(Math.Pow(x1 - x2, 2) + Math.Pow(y1 - y2, 2));

static double PointLineDistance(double px, double py, double x1, double y1, double x2, double y2)
{
    var dx = x2 - x1; var dy = y2 - y1;
    if (dx == 0 && dy == 0) return Distance(px, py, x1, y1);
    var t = Math.Clamp(((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy), 0, 1);
    return Distance(px, py, x1 + t * dx, y1 + t * dy);
}

readonly record struct Rgba(byte R, byte G, byte B, byte A);
