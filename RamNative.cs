using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class RamNative {
 [StructLayout(LayoutKind.Sequential)] struct MemoryCounters {
  public uint Size,Faults;
  public UIntPtr PeakWS,WS,PeakPaged,Paged,PeakNonPaged,NonPaged,Pagefile,PeakPagefile,PrivateCommit,PrivateWS;
  public ulong SharedCommit;
 }
 [DllImport("psapi.dll",SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr h,ref MemoryCounters counters,uint size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("psapi.dll",SetLastError=true)] static extern bool QueryWorkingSet(IntPtr h,IntPtr buffer,int size);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessWorkingSetSizeEx(IntPtr h,out UIntPtr min,out UIntPtr max,out uint flags);
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetProcessWorkingSetSizeEx(IntPtr h,UIntPtr min,UIntPtr max,uint flags);
 [StructLayout(LayoutKind.Sequential)] struct TP { public uint Count; public uint Low; public int High; public uint Attributes; }
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr h,uint access,out IntPtr token);
 [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out long luid);
 [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr token,bool disable,ref TP state,uint length,IntPtr previous,IntPtr returned);
 static void EnablePrivilege() {
  IntPtr token;
  using(var p=System.Diagnostics.Process.GetCurrentProcess()) { if(!OpenProcessToken(p.Handle,0x28,out token)) return; }
  try { long luid; if(!LookupPrivilegeValue(null,"SeIncreaseWorkingSetPrivilege",out luid)) return;
   var tp=new TP {Count=1,Low=(uint)luid,High=(int)(luid>>32),Attributes=2}; AdjustTokenPrivileges(token,false,ref tp,0,IntPtr.Zero,IntPtr.Zero);
  } finally {CloseHandle(token);}
 }
 // Each entry represents a resident page; Shared (bit 8) marks shareable pages.
 // Private commit is deliberately not used as a substitute for resident memory.
 public static ulong[] Memory(int pid) {
  IntPtr h=OpenProcess(0x0410,false,pid);
  if(h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
  try {
   // EX2 gives both counters directly on updated Windows 10/11.
   // A sentinel detects older Windows that do not fill the extended field.
   var counters=new MemoryCounters(); counters.Size=(uint)Marshal.SizeOf(typeof(MemoryCounters));
   counters.PrivateWS=UIntPtr.Size==8 ? new UIntPtr(ulong.MaxValue) : new UIntPtr(uint.MaxValue);
   ulong sentinel=counters.PrivateWS.ToUInt64();
   if(GetProcessMemoryInfo(h,ref counters,counters.Size) && counters.PrivateWS.ToUInt64()!=sentinel && counters.PrivateWS.ToUInt64()<=counters.WS.ToUInt64())
    return new ulong[] {counters.PrivateWS.ToUInt64(),counters.WS.ToUInt64()};
   int size=65536;
   for(int attempt=0;attempt<6;attempt++) {
    IntPtr buffer=Marshal.AllocHGlobal(size);
    try {
     Marshal.WriteIntPtr(buffer,IntPtr.Zero);
     if(!QueryWorkingSet(h,buffer,size)) {
      int error=Marshal.GetLastWin32Error(); if(error!=24) throw new Win32Exception(error);
      long needed=Marshal.ReadIntPtr(buffer).ToInt64();
      size=checked((int)Math.Max(size*2L,(needed+16385)*IntPtr.Size)); continue;
     }
     long count=Marshal.ReadIntPtr(buffer).ToInt64();
     if(count<0||count>size/IntPtr.Size-1) throw new InvalidOperationException("Invalid working set snapshot");
     ulong privatePages=0;
     for(int i=0;i<count;i++) {long entry=Marshal.ReadIntPtr(buffer,(i+1)*IntPtr.Size).ToInt64(); if((entry&0x100)==0) privatePages++;}
     return new ulong[] {privatePages*(ulong)Environment.SystemPageSize,(ulong)count*(ulong)Environment.SystemPageSize};
    } finally {Marshal.FreeHGlobal(buffer);}
   }
   throw new InvalidOperationException("Working set changed too quickly");
  } finally {CloseHandle(h);}
 }
 public static ulong[] Read(int pid) {
  IntPtr h=OpenProcess(0x0400,false,pid); if(h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
  try {UIntPtr min,max;uint flags; if(!GetProcessWorkingSetSizeEx(h,out min,out max,out flags)) throw new Win32Exception(Marshal.GetLastWin32Error());
   return new ulong[] {min.ToUInt64(),max.ToUInt64(),flags};
  } finally {CloseHandle(h);}
 }
 public static void Set(int pid,ulong min,ulong max,uint flags) {
  EnablePrivilege(); IntPtr h=OpenProcess(0x0100,false,pid); if(h==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
  try {if(!SetProcessWorkingSetSizeEx(h,new UIntPtr(min),new UIntPtr(max),flags)) throw new Win32Exception(Marshal.GetLastWin32Error());}
  finally {CloseHandle(h);}
 }
}