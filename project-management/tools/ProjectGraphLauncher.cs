using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;

internal static class ProjectGraphLauncher
{
    private static int Main(string[] args)
    {
        string executableDirectory = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        string projectRoot = executableDirectory;
        string script = Path.Combine(projectRoot, "scripts", "pm.ps1");

        if (!File.Exists(script))
        {
            ShowError("找不到项目管理脚本：" + script + Environment.NewLine + "请将本程序放在项目管理目录根目录中。");
            return 2;
        }

        bool exportPdf = args.Length > 0 && string.Equals(args[0], "--pdf", StringComparison.OrdinalIgnoreCase);
        bool showHelp = args.Length > 0 && (string.Equals(args[0], "--help", StringComparison.OrdinalIgnoreCase) || string.Equals(args[0], "/?", StringComparison.OrdinalIgnoreCase));
        if (showHelp)
        {
            ShowInfo("双击：生成并打开项目网络图\n\n命令行参数：\n  --pdf    生成并打开 PDF\n  --help   显示帮助");
            return 0;
        }

        string relativeOutput = exportPdf ? @".project\exports\项目图谱.pdf" : @".project\exports\项目图谱.html";
        string output = Path.Combine(projectRoot, relativeOutput);
        string command = exportPdf ? "export-pdf" : "graph";
        string powershellPath = FindPowerShell();
        string scriptToRun = script;
        string temporaryScript = null;
        if (Path.GetFileName(powershellPath).Equals("powershell.exe", StringComparison.OrdinalIgnoreCase))
        {
            temporaryScript = Path.Combine(Path.GetDirectoryName(script), ".pm-launcher-" + Guid.NewGuid().ToString("N") + ".ps1");
            File.WriteAllText(temporaryScript, File.ReadAllText(script, Encoding.UTF8), new UTF8Encoding(true));
            scriptToRun = temporaryScript;
        }
        string arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(scriptToRun) + " " + command + " -OutputPath " + Quote(relativeOutput);

        ProcessStartInfo startInfo = new ProcessStartInfo
        {
            FileName = powershellPath,
            Arguments = arguments,
            WorkingDirectory = projectRoot,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = false,
            StandardOutputEncoding = Encoding.UTF8
        };

        try
        {
            using (Process process = Process.Start(startInfo))
            {
                string standardOutput = process.StandardOutput.ReadToEnd();
                process.WaitForExit();
                if (process.ExitCode != 0 || !File.Exists(output))
                {
                    ShowError("生成项目网络图失败。\n\n" + standardOutput);
                    return process.ExitCode == 0 ? 1 : process.ExitCode;
                }
            }

            if (exportPdf) OpenFile(output);
            else RunApplicationWindow(output, Path.GetFullPath(Path.Combine(projectRoot, "..")));
            return 0;
        }
        catch (Exception ex)
        {
            ShowError("启动项目网络图失败：\n\n" + ex.Message);
            return 1;
        }
        finally
        {
            if (!string.IsNullOrEmpty(temporaryScript) && File.Exists(temporaryScript))
            {
                try { File.Delete(temporaryScript); } catch { }
            }
        }
    }

    private static string FindPowerShell()
    {
        string pathEnvironment = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (string directory in pathEnvironment.Split(new[] { Path.PathSeparator }, StringSplitOptions.RemoveEmptyEntries))
        {
            string pathCandidate = Path.Combine(directory.Trim(), "pwsh.exe");
            if (File.Exists(pathCandidate)) return pathCandidate;
        }
        string userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        string[] candidates =
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"),
            Path.Combine(userProfile, @".cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe")
        };
        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate)) return candidate;
        }
        return "powershell.exe";
    }

    private static void RunApplicationWindow(string htmlPath, string allowedRoot)
    {
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        string appUrl = "http://127.0.0.1:" + port + "/";
        string[] browserCandidates =
        {
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Microsoft\Edge\Application\msedge.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"Microsoft\Edge\Application\msedge.exe")
        };
        string browserPath = null;
        foreach (string candidate in browserCandidates)
        {
            if (File.Exists(candidate))
            {
                browserPath = candidate;
                break;
            }
        }
        if (browserPath != null)
        {
            Process.Start(new ProcessStartInfo { FileName = browserPath, Arguments = "--app=" + Quote(appUrl), UseShellExecute = false, CreateNoWindow = true });
        }
        else
        {
            Process.Start(new ProcessStartInfo { FileName = "explorer.exe", Arguments = appUrl, UseShellExecute = false, CreateNoWindow = true });
        }

        string html = File.ReadAllText(htmlPath, Encoding.UTF8);
        bool running = true;
        while (running)
        {
            TcpClient client = null;
            try
            {
                client = listener.AcceptTcpClient();
                using (NetworkStream stream = client.GetStream())
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8))
                {
                    string requestLine = reader.ReadLine();
                    string line;
                    while (!string.IsNullOrEmpty(line = reader.ReadLine())) { }
                    if (string.IsNullOrEmpty(requestLine)) continue;
                    string[] requestParts = requestLine.Split(' ');
                    string requestTarget = requestParts.Length > 1 ? requestParts[1] : "/";
                    string body = "";
                    int status = 200;
                    string contentType = "text/plain; charset=utf-8";

                    if (requestTarget.StartsWith("/open?path=", StringComparison.OrdinalIgnoreCase))
                    {
                        string encoded = requestTarget.Substring("/open?path=".Length);
                        string path = Uri.UnescapeDataString(encoded.Replace("+", "%20"));
                        string rootPrefix = allowedRoot.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                        string fullPath = Path.GetFullPath(path);
                        if ((fullPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase) || string.Equals(fullPath, allowedRoot, StringComparison.OrdinalIgnoreCase)) && File.Exists(fullPath))
                        {
                            try
                            {
                                Process.Start(new ProcessStartInfo { FileName = fullPath, UseShellExecute = true });
                                body = "已交给 Windows 默认程序打开。";
                            }
                            catch (Exception ex) { status = 500; body = ex.Message; }
                        }
                        else { status = 404; body = "文件不存在，或文件位于允许目录之外。"; }
                    }
                    else if (requestTarget.StartsWith("/shutdown", StringComparison.OrdinalIgnoreCase))
                    {
                        body = "closed";
                        running = false;
                    }
                    else if (requestTarget == "/" || requestTarget.StartsWith("/?", StringComparison.Ordinal))
                    {
                        body = html;
                        contentType = "text/html; charset=utf-8";
                    }
                    else { status = 404; body = "Not found"; }

                    byte[] bytes = Encoding.UTF8.GetBytes(body);
                    byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + (status == 200 ? " OK" : " Not Found") + "\r\nContent-Type: " + contentType + "\r\nContent-Length: " + bytes.Length + "\r\nConnection: close\r\n\r\n");
                    stream.Write(header, 0, header.Length);
                    stream.Write(bytes, 0, bytes.Length);
                }
            }
            catch (Exception)
            {
                // Ignore browser probes and transient local connection failures.
            }
            finally { if (client != null) client.Close(); }
        }
        listener.Stop();
    }

    private static void OpenFile(string path)
    {
        Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true });
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void ShowInfo(string message)
    {
        Console.WriteLine(message);
    }

    private static void ShowError(string message)
    {
        Console.Error.WriteLine(message);
        try
        {
            Type messageBox = Type.GetType("System.Windows.Forms.MessageBox, System.Windows.Forms");
            if (messageBox != null)
            {
                System.Reflection.MethodInfo method = messageBox.GetMethod("Show", new[] { typeof(string), typeof(string) });
                if (method != null)
                {
                    method.Invoke(null, new object[] { message, "项目网络图" });
                }
            }
        }
        catch
        {
            // The console fallback above is sufficient when Windows Forms is unavailable.
        }
    }
}
