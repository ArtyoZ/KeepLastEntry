using System.Reflection;
using System.Runtime.InteropServices;

// General assembly info. KeePass identifies a compiled PLGX as a valid
// plugin partly by checking AssemblyProduct == "KeePass Plugin" — keep
// that value exactly as-is.
[assembly: AssemblyTitle("KeepLastEntry")]
[assembly: AssemblyDescription("Restores the last selected KeePass entry independently of the KDBX save state.")]
[assembly: AssemblyCompany("Artyom Zhurkin")]
[assembly: AssemblyProduct("KeePass Plugin")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

[assembly: ComVisible(false)]
[assembly: Guid("6a7b6b9e-6b0e-4a1e-9d63-5f7a0a2f7c31")]
