using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SIPSorcery.Net;
using SIPSorcery.SIP.App;

if (args.Length != 1) throw new ArgumentException("用法：RemoteControl.WebRtcSmoke.exe http://localhost:28783");
var endpoint = args[0].TrimEnd('/');
using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
using var profileDocument = JsonDocument.Parse(await http.GetStringAsync(endpoint + "/api/pairing/profile"));
var profile = profileDocument.RootElement;
var token = profile.GetProperty("pairingToken").GetString()!;
var key = Convert.FromBase64String(profile.GetProperty("sessionKeyBase64").GetString()!);

var peer = new RTCPeerConnection(null);
var connected = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
var channelOpen = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
peer.onconnectionstatechange += state =>
{
    Console.WriteLine($"connectionState={state}");
    if (state == RTCPeerConnectionState.connected) connected.TrySetResult();
    if (state is RTCPeerConnectionState.failed or RTCPeerConnectionState.closed)
        connected.TrySetException(new InvalidOperationException($"WebRTC connection state: {state}"));
};
var channel = await peer.createDataChannel("remote-control", new RTCDataChannelInit { ordered = true });
channel.onopen += () => channelOpen.TrySetResult();

var offer = peer.createOffer();
await peer.setLocalDescription(offer);
await WaitForIceGatheringAsync(peer);

var request = new
{
    type = "offer",
    sdp = peer.localDescription.sdp.ToString()
};
using var message = new HttpRequestMessage(HttpMethod.Post, endpoint + "/api/webrtc/offer");
message.Headers.Add("X-Remote-Control-Token", token);
message.Content = new StringContent(Encrypt(request, key), Encoding.UTF8, "text/plain");
using var response = await http.SendAsync(message);
response.EnsureSuccessStatusCode();
using var answerDocument = Decrypt(await response.Content.ReadAsStringAsync(), key);
var answerSdp = answerDocument.RootElement.GetProperty("sdp").GetString()!;
var answerResult = peer.SetRemoteDescription(SdpType.answer, SDP.ParseSDPDescription(answerSdp)!);
if (answerResult != SetDescriptionResultEnum.OK) throw new InvalidOperationException($"answer rejected: {answerResult}");

await connected.Task.WaitAsync(TimeSpan.FromSeconds(10));
await channelOpen.Task.WaitAsync(TimeSpan.FromSeconds(10));
channel.send(JsonSerializer.Serialize(new { kind = "pointer", x = 0.5, y = 0.5 }));
Console.WriteLine("webrtcSmoke=ok dataChannelMessageSent=true");
peer.Close("smoke complete");

static async Task WaitForIceGatheringAsync(RTCPeerConnection peer)
{
    if (peer.iceGatheringState == RTCIceGatheringState.complete) return;
    var complete = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    void Handler(RTCIceGatheringState state) { if (state == RTCIceGatheringState.complete) complete.TrySetResult(); }
    peer.onicegatheringstatechange += Handler;
    try { await complete.Task.WaitAsync(TimeSpan.FromSeconds(3)); }
    catch (TimeoutException) { }
    finally { peer.onicegatheringstatechange -= Handler; }
}

static string Encrypt(object value, byte[] key)
{
    var plain = JsonSerializer.SerializeToUtf8Bytes(value);
    var nonce = RandomNumberGenerator.GetBytes(12);
    var cipher = new byte[plain.Length];
    var tag = new byte[16];
    using var aes = new AesGcm(key, 16);
    aes.Encrypt(nonce, plain, cipher, tag);
    return Convert.ToBase64String(nonce.Concat(cipher).Concat(tag).ToArray());
}

static JsonDocument Decrypt(string encoded, byte[] key)
{
    var data = Convert.FromBase64String(encoded);
    var nonce = data[..12];
    var tag = data[^16..];
    var cipher = data[12..^16];
    var plain = new byte[cipher.Length];
    using var aes = new AesGcm(key, 16);
    aes.Decrypt(nonce, cipher, tag, plain);
    return JsonDocument.Parse(Encoding.UTF8.GetString(plain));
}
