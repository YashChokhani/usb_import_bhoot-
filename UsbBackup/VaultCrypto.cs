using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;

// Windows PowerShell 5.1 / .NET Framework 4.7.2+. No external dependencies.
namespace UsbVault {
    public static class Crypto {
        static readonly byte[] Magic = Encoding.ASCII.GetBytes("USBVLT01");
        // Unique to this deployment drive. This prevents another UsbVault kit on
        // the same Windows account from silently sharing its recovery key.
        // Re-keyed replica: fresh key identity, independent of the original kit.
        public const string KeyName = "UsbVault-Recovery-v1-cf4a3d70dea84442a69b96060152bc70";
        static byte[] Random(int n) { var b = new byte[n]; using (var r = RandomNumberGenerator.Create()) r.GetBytes(b); return b; }
        static byte[] ReadExactly(Stream s, int n) {
            var b = new byte[n]; int p = 0, k;
            while (p < n && (k = s.Read(b, p, n-p)) > 0) p += k;
            if (p != n) throw new InvalidDataException("Truncated backup."); return b;
        }
        static bool Equal(byte[] a, byte[] b) {
            if (a.Length != b.Length) return false; int d = 0;
            for (int i=0; i<a.Length; i++) d |= a[i] ^ b[i]; return d == 0;
        }
        public static string Hash(string value) {
            using (var h = SHA256.Create()) return BitConverter.ToString(h.ComputeHash(Encoding.UTF8.GetBytes(value))).Replace("-", "").ToLowerInvariant();
        }
        public static string PrepareKey() {
            var provider = CngProvider.MicrosoftSoftwareKeyStorageProvider;
            if (!CngKey.Exists(KeyName, provider)) {
                var p = new CngKeyCreationParameters { Provider = provider, ExportPolicy = CngExportPolicies.None, KeyUsage = CngKeyUsages.Decryption };
                p.Parameters.Add(new CngProperty("Length", BitConverter.GetBytes(3072), CngPropertyOptions.None));
                using (var k = CngKey.Create(CngAlgorithm.Rsa, KeyName, p)) { }
            }
            using (var k = CngKey.Open(KeyName, provider))
            using (var rsa = new RSACng(k)) {
                if (k.ExportPolicy != CngExportPolicies.None || rsa.KeySize < 3072)
                    throw new CryptographicException("Existing recovery key has unexpected protection. Refusing to replace it.");
                return rsa.ToXmlString(false);
            }
        }
        public static RSACng OpenPrivateKey() {
            return new RSACng(CngKey.Open(KeyName, CngProvider.MicrosoftSoftwareKeyStorageProvider));
        }
        public static RSACng PublicKey(string xml) {
            if (xml.Contains("<D>") || xml.Contains("<P>")) throw new InvalidDataException("Private keys are forbidden in the deployment kit.");
            var rsa = new RSACng();
            try { rsa.FromXmlString(xml); if (rsa.KeySize < 3072) throw new InvalidDataException("RSA key too small."); return rsa; }
            catch { rsa.Dispose(); throw; }
        }
        // MAC every header and ciphertext byte. Written files become visible only by atomic rename.
        public static string HashFile(string source, string heartbeat) {
            using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var hash = SHA256.Create()) {
                byte[] b = new byte[1048576]; int n; DateTime pulse = DateTime.UtcNow;
                try { while ((n=input.Read(b,0,b.Length)) > 0) {
                    hash.TransformBlock(b,0,n,null,0);
                    if (!String.IsNullOrEmpty(heartbeat) && (DateTime.UtcNow-pulse).TotalSeconds >= 10) { File.SetLastWriteTimeUtc(heartbeat,DateTime.UtcNow); pulse=DateTime.UtcNow; }
                } hash.TransformFinalBlock(new byte[0],0,0); return BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant(); }
                finally { Array.Clear(b,0,b.Length); }
            }
        }
        public static string EncryptFile(string source, string output, string relative, string volume, RSA rsa, long reserveBytes, string heartbeat) {
            if (File.Exists(output)) throw new IOException("Backup object already exists.");
            byte[] keys = Random(64), iv = Random(16);
            string temp = output + ".partial", digest = null;
            try {
                CheckRelative(relative);
                using (var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    var info = new FileInfo(source);
                    if ((info.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Reparse points are excluded.");
                    long length = input.Length, ticks = info.LastWriteTimeUtc.Ticks;
                    var disk = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(output)));
                    if (disk.AvailableFreeSpace < checked(length + reserveBytes + 65536)) throw new IOException("Insufficient free space; backup postponed.");
                    byte[] wrapped = rsa.Encrypt(keys, RSAEncryptionPadding.OaepSHA256);
                    using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1048576, FileOptions.SequentialScan))
                    using (var aes = Aes.Create())
                    using (var hash = SHA256.Create()) {
                        aes.Key = Slice(keys, 0, 32); aes.IV = iv; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                        using (var mac = new HMACSHA256(Slice(keys, 32, 32))) {
                            var sink = new MacWriter(file, mac);
                            sink.Write(Magic, 0, Magic.Length);
                            byte[] count = BitConverter.GetBytes(wrapped.Length);
                            sink.Write(count, 0, count.Length); sink.Write(wrapped, 0, wrapped.Length); sink.Write(iv, 0, iv.Length);
                            using (var cipher = new CryptoStream(sink, aes.CreateEncryptor(), CryptoStreamMode.Write, true)) {
                                using (var meta = new BinaryWriter(cipher, Encoding.UTF8, true)) {
                                    WriteText(meta, relative); WriteText(meta, volume); meta.Write(ticks); meta.Write(length); meta.Flush();
                                }
                                byte[] buffer = new byte[1048576]; int n; long total = 0;
                                DateTime pulse = DateTime.UtcNow;
                                try { while ((n = input.Read(buffer, 0, buffer.Length)) > 0) {
                                    cipher.Write(buffer, 0, n); hash.TransformBlock(buffer, 0, n, null, 0); total += n;
                                    if (!String.IsNullOrEmpty(heartbeat) && (DateTime.UtcNow-pulse).TotalSeconds >= 10) { File.SetLastWriteTimeUtc(heartbeat, DateTime.UtcNow); pulse = DateTime.UtcNow; }
                                } }
                                finally { Array.Clear(buffer, 0, buffer.Length); }
                                if (total != length) throw new IOException("Source changed while being read.");
                                hash.TransformFinalBlock(new byte[0], 0, 0); digest = BitConverter.ToString(hash.Hash).Replace("-", "").ToLowerInvariant();
                                cipher.FlushFinalBlock();
                            }
                            mac.TransformFinalBlock(new byte[0], 0, 0); file.Write(mac.Hash, 0, 32); file.Flush(true);
                        }
                    }
                }
                File.Move(temp, output); return digest;
            } finally { Array.Clear(keys, 0, keys.Length); if (File.Exists(temp)) File.Delete(temp); }
        }
        public static string RestoreFile(string source, string destination, RSA rsa) {
            byte[] keys = null;
            string temp = null;
            try {
                using (var file = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                    if (!Equal(ReadExactly(file, 8), Magic)) throw new InvalidDataException("Unknown backup format.");
                    int size = BitConverter.ToInt32(ReadExactly(file, 4), 0);
                    if (size != rsa.KeySize / 8) throw new InvalidDataException("Wrong key or damaged header.");
                    keys = rsa.Decrypt(ReadExactly(file, size), RSAEncryptionPadding.OaepSHA256);
                    if (keys.Length != 64) throw new InvalidDataException("Invalid key material.");
                    byte[] iv = ReadExactly(file, 16); long start = file.Position, end = file.Length - 32;
                    if (end <= start || (end-start) % 16 != 0) throw new InvalidDataException("Truncated ciphertext.");
                    // Authenticate the complete envelope BEFORE writing any plaintext.
                    using (var mac = new HMACSHA256(Slice(keys, 32, 32))) {
                        file.Position = 0; byte[] buffer = new byte[1048576]; long left = end;
                        while (left > 0) { int n = file.Read(buffer, 0, (int)Math.Min(buffer.Length, left)); if (n == 0) throw new EndOfStreamException(); mac.TransformBlock(buffer, 0, n, null, 0); left -= n; }
                        mac.TransformFinalBlock(new byte[0], 0, 0);
                        if (!Equal(mac.Hash, ReadExactly(file, 32))) throw new CryptographicException("Authentication failed. Backup damaged or modified.");
                    }
                    file.Position = start;
                    using (var aes = Aes.Create()) {
                        aes.Key = Slice(keys, 0, 32); aes.IV = iv; aes.Mode = CipherMode.CBC; aes.Padding = PaddingMode.PKCS7;
                        using (var cipher = new CryptoStream(new LimitedReader(file, end-start), aes.CreateDecryptor(), CryptoStreamMode.Read))
                        using (var meta = new BinaryReader(cipher, Encoding.UTF8, true)) {
                            string relative = ReadText(meta), volume = ReadText(meta);
                            long ticks = meta.ReadInt64(), length = meta.ReadInt64();
                            CheckRelative(relative);
                            if (length < 0 || length > end-start || ticks < DateTime.MinValue.Ticks || ticks > DateTime.MaxValue.Ticks) throw new InvalidDataException("Invalid metadata.");
                            string root = Path.GetFullPath(destination).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                            string target = Path.GetFullPath(Path.Combine(root, Hash(volume).Substring(0,24), relative));
                            if (!target.StartsWith(root, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unsafe path.");
                            EnsureSafeDirectory(Path.GetDirectoryName(target));
                            // Preserve all historical versions, never overwrite a restored file.
                            if (File.Exists(target) || Directory.Exists(target)) target += ".version-" + Guid.NewGuid().ToString("N");
                            temp = Path.Combine(Path.GetDirectoryName(target), ".restore-" + Guid.NewGuid().ToString("N") + ".partial");
                            using (var output = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) {
                                byte[] buffer = new byte[1048576]; long left = length;
                                try { while (left > 0) { int n = cipher.Read(buffer, 0, (int)Math.Min(left, buffer.Length)); if (n == 0) throw new EndOfStreamException(); output.Write(buffer, 0, n); left -= n; } }
                                finally { Array.Clear(buffer, 0, buffer.Length); }
                                if (cipher.ReadByte() != -1) throw new InvalidDataException("Unexpected payload length."); output.Flush(true);
                            }
                            File.SetLastWriteTimeUtc(temp, new DateTime(ticks, DateTimeKind.Utc));
                            File.Move(temp, target); temp = null; return target;
                        }
                    }
                }
            } finally { if (keys != null) Array.Clear(keys, 0, keys.Length); if (temp != null && File.Exists(temp)) File.Delete(temp); }
        }
        public static void CheckRelative(string path) {
            if (String.IsNullOrWhiteSpace(path) || Path.IsPathRooted(path) || path.IndexOf(':') >= 0 || path.IndexOf('/') >= 0) throw new InvalidDataException("Unsafe relative path.");
            foreach (string part in path.Split('\\')) {
                if (part.Length == 0 || part == "." || part == ".." || part.TrimEnd(' ', '.') != part || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
                    throw new InvalidDataException("Unsafe path component.");
                string stem = part.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" || System.Text.RegularExpressions.Regex.IsMatch(stem, @"^(COM|LPT)[0-9¹²³]$")) throw new InvalidDataException("Device path forbidden.");
            }
        }
        public static void EnsureSafeDirectory(string path) {
            var info = new DirectoryInfo(Path.GetFullPath(path));
            if (info.Parent != null) EnsureSafeDirectory(info.Parent.FullName);
            if (info.Exists) { if ((info.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Reparse-point destination forbidden."); }
            else info.Create();
        }
        static byte[] Slice(byte[] b, int start, int size) { var v = new byte[size]; Buffer.BlockCopy(b,start,v,0,size); return v; }
        static void WriteText(BinaryWriter writer, string text) { byte[] b = Encoding.UTF8.GetBytes(text); if (b.Length > 32768) throw new InvalidDataException("Metadata too large."); writer.Write(b.Length); writer.Write(b); }
        static string ReadText(BinaryReader reader) { int n=reader.ReadInt32(); if(n<0 || n>32768) throw new InvalidDataException("Invalid metadata size."); byte[] b=reader.ReadBytes(n); if(b.Length!=n) throw new EndOfStreamException(); return new UTF8Encoding(false,true).GetString(b); }
        sealed class MacWriter : Stream {
            readonly Stream inner; readonly HMAC mac;
            public MacWriter(Stream stream, HMAC hash) { inner=stream; mac=hash; }
            public override void Write(byte[] b,int o,int n) { inner.Write(b,o,n); mac.TransformBlock(b,o,n,null,0); }
            public override void Flush() { inner.Flush(); }
            public override bool CanRead { get { return false; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return true; } }
            public override long Length { get { throw new NotSupportedException(); } } public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override int Read(byte[] b,int o,int n) { throw new NotSupportedException(); } public override long Seek(long o,SeekOrigin s) { throw new NotSupportedException(); } public override void SetLength(long n) { throw new NotSupportedException(); }
        }
        sealed class LimitedReader : Stream {
            readonly Stream inner; long remaining;
            public LimitedReader(Stream stream,long size) { inner=stream; remaining=size; }
            public override int Read(byte[] b,int o,int n) { if(remaining==0) return 0; int got=inner.Read(b,o,(int)Math.Min(n,remaining)); if(got==0) throw new EndOfStreamException(); remaining-=got; return got; }
            public override bool CanRead { get { return true; } } public override bool CanSeek { get { return false; } } public override bool CanWrite { get { return false; } }
            public override long Length { get { throw new NotSupportedException(); } } public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
            public override void Flush() { } public override void Write(byte[] b,int o,int n) { throw new NotSupportedException(); } public override long Seek(long o,SeekOrigin s) { throw new NotSupportedException(); } public override void SetLength(long n) { throw new NotSupportedException(); }
        }
    }
}
