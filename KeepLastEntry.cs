using System;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Forms;

using KeePass.Forms;
using KeePass.Plugins;
using KeePass.Util;
using KeePassLib;
using KeePassLib.Collections;
using KeePassLib.Serialization;
using KeePassLib.Utility;

namespace KeepLastEntry
{
    public sealed class KeepLastEntryExt : Plugin
    {
        private const string UpdateInformationUrl =
            "https://raw.githubusercontent.com/ArtyoZ/KeepLastEntry/refs/heads/main/KeepLastEntry-version.txt";

        private const string UpdateInformationPublicKey =
            "<RSAKeyValue><Modulus>n8Hn2ExH6PXhYDTU4QFum6+RNHIOAn/+p7RFg4pzUnvOgJbyufJl7xXI6tl0oW9Z7hC2IzH/sQEdA2jw32F8jUqIkjfbBMfKf5B6njKGBopyB/F0m4g9okkpXyA7HhNqV2uI8RgGAthH3GllgcdZAssu0WgAiQZrYuYTqOysQZUM/hjX1gzscgJQXZZqlcEFJPHjAeS2+Hhmi36trhlXbFHU6f/H7NL6kXcHBoTsLTdBkPMJWtfSUubbt54tOUdWgW6RSS5ngnCvQAHvt0T+sblaAt05DsA5NqYM11sSoxaT/t2aUL6BfcHVu9BvsxZw1YwhQi1hi1F2hPs5xzttyE02b2egBk6efZKTEsr2sIvWnP9WYKI4ThTakU2U5X5Id/y89R0/xGoOnv2tqHIwFHNqdl9cCoy/tgK4OvK+rzMl95VvNVSZ719pgsM5pJJ39ulaSdNjDd3h6NUYF3CbvW+da+UGk+ocdzOAEASl9AEPeCew693gnhLePZateN+LkxD63aW6fwTi3AI8qw1vaiUqTLzfGNqSZUcqgoFnFk943gBAmiDhIkIDNEVDd/4vEvn7V2M7e9HDeXHNpnDBlMlKhrr0P6oQugflhNiMJslvKkT2nSo8L3MxVQxopVNWm9XsTKF8Za6xKI7H1KKjW+EDvTprIfSCAgHQFcjEfIc=</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>";

        public override string UpdateUrl
        {
            get { return UpdateInformationUrl; }
        }

        private const string ConfigPrefix = "KeepLastEntry.Entry.";
        private IPluginHost m_host;
        private bool m_restoring;
        private bool m_terminated;

        public override bool Initialize(IPluginHost host)
        {
            if(host == null) return false;

            m_host = host;

            UpdateCheckEx.SetFileSigKey(UpdateUrl, UpdateInformationPublicKey);

            Application.Idle += OnApplicationIdle;
            m_host.MainWindow.FileOpened += OnFileOpened;
            m_host.MainWindow.DocumentManager.ActiveDocumentSelected += OnActiveDocumentSelected;

            return true;
        }

        public override void Terminate()
        {
            m_terminated = true;

            try { Application.Idle -= OnApplicationIdle; }
            catch(Exception) { }

            if(m_host != null)
            {
                try { m_host.MainWindow.FileOpened -= OnFileOpened; }
                catch(Exception) { }

                try { m_host.MainWindow.DocumentManager.ActiveDocumentSelected -= OnActiveDocumentSelected; }
                catch(Exception) { }
            }

            m_host = null;
        }

        private void OnApplicationIdle(object sender, EventArgs e)
        {
            if(m_terminated || m_restoring || m_host == null) return;

            try
            {
                PwDatabase db = m_host.Database;
                if(db == null || !db.IsOpen) return;

                PwEntry entry = m_host.MainWindow.GetSelectedEntry(false);
                if(entry == null || entry.Uuid == null || entry.Uuid.IsZero) return;

                string dbKey = GetDatabaseKey(db);
                if(string.IsNullOrEmpty(dbKey)) return;

                string key = ConfigPrefix + dbKey;
                string uuid = entry.Uuid.ToHexString();

                if(!string.Equals(m_host.CustomConfig.GetString(key, null),
                    uuid, StringComparison.OrdinalIgnoreCase))
                {
                    m_host.CustomConfig.SetString(key, uuid);
                }
            }
            catch(Exception)
            {
                // Never interfere with normal KeePass operation.
            }
        }

        private void OnFileOpened(object sender, FileOpenedEventArgs e)
        {
            if(e == null || e.Database == null || !e.Database.IsOpen) return;
            ScheduleRestore(e.Database);
        }

        private void OnActiveDocumentSelected(object sender, EventArgs e)
        {
            if(m_host == null) return;

            try
            {
                PwDatabase db = m_host.Database;
                if(db != null && db.IsOpen)
                    ScheduleRestore(db);
            }
            catch(Exception)
            {
            }
        }

        private void ScheduleRestore(PwDatabase db)
        {
            if(m_host == null || db == null || !db.IsOpen) return;

            try
            {
                m_host.MainWindow.BeginInvoke((MethodInvoker)delegate
                {
                    RestoreLastEntry(db);
                });
            }
            catch(Exception)
            {
            }
        }

        private void RestoreLastEntry(PwDatabase db)
        {
            if(m_host == null || db == null || !db.IsOpen) return;

            string dbKey = GetDatabaseKey(db);
            if(string.IsNullOrEmpty(dbKey)) return;

            string key = ConfigPrefix + dbKey;
            string hex = m_host.CustomConfig.GetString(key, null);
            if(string.IsNullOrEmpty(hex)) return;

            byte[] uuidBytes;
            try
            {
                uuidBytes = MemUtil.HexStringToByteArray(hex);
            }
            catch(Exception)
            {
                return;
            }

            if(uuidBytes == null || uuidBytes.Length != (int)PwUuid.UuidSize)
                return;

            PwEntry entry;
            try
            {
                PwUuid uuid = new PwUuid(uuidBytes);
                entry = db.RootGroup.FindEntry(uuid, true);
            }
            catch(Exception)
            {
                return;
            }

            if(entry == null)
            {
                // The remembered entry was deleted.
                m_host.CustomConfig.SetString(key, string.Empty);
                return;
            }

            m_restoring = true;
            try
            {
                PwGroup parent = entry.ParentGroup;
                if(parent != null)
                {
                    m_host.MainWindow.UpdateUI(
                        false, null, true, parent, true, null, false);
                }

                SelectEntryUsingKeePass(entry);
            }
            catch(Exception)
            {
            }
            finally
            {
                m_restoring = false;
            }
        }

        private void SelectEntryUsingKeePass(PwEntry entry)
        {
            Type t = m_host.MainWindow.GetType();

            MethodInfo mi = FindMethod(t, "SelectEntry", 5);
            if(mi != null)
            {
                mi.Invoke(m_host.MainWindow, new object[]
                {
                    entry, true, true, true, true
                });
                return;
            }

            mi = FindMethod(t, "SelectEntries", 5);
            if(mi != null)
            {
                PwObjectList<PwEntry> list = new PwObjectList<PwEntry>();
                list.Add(entry);
                mi.Invoke(m_host.MainWindow, new object[]
                {
                    list, true, true, true, true
                });
                return;
            }

            mi = FindMethod(t, "SelectEntries", 3);
            if(mi != null)
            {
                PwObjectList<PwEntry> list = new PwObjectList<PwEntry>();
                list.Add(entry);
                mi.Invoke(m_host.MainWindow, new object[]
                {
                    list, true, true
                });
            }
        }

        private static MethodInfo FindMethod(Type type, string name, int parameterCount)
        {
            MethodInfo[] methods = type.GetMethods(
                BindingFlags.Instance | BindingFlags.Public |
                BindingFlags.NonPublic);

            foreach(MethodInfo mi in methods)
            {
                if(mi.Name == name &&
                    mi.GetParameters().Length == parameterCount)
                    return mi;
            }

            return null;
        }

        private static string GetDatabaseKey(PwDatabase db)
        {
            if(db == null || db.IOConnectionInfo == null) return null;

            string path = db.IOConnectionInfo.Path;
            if(string.IsNullOrEmpty(path)) return null;

            string normalized = path;
            if(path.IndexOf("://", StringComparison.Ordinal) < 0)
                normalized = path.Trim().ToLowerInvariant();

            using(SHA256 sha = SHA256.Create())
            {
                byte[] data = Encoding.UTF8.GetBytes(normalized);
                byte[] hash = sha.ComputeHash(data);
                return MemUtil.ByteArrayToHexString(hash);
            }
        }
    }
}
