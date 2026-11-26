using System.Runtime.InteropServices;

namespace Jack.WinUI;

// Selector de archivos/carpetas del sistema (IFileOpenDialog). Los selectores de WinRT fallan con COMException
// cuando la app corre elevada; este diálogo clásico funciona siempre.
public static class NativePicker
{
    private const uint PickFolders = 0x20, AllowMultiple = 0x200, ForceFileSystem = 0x40, PathMustExist = 0x800;
    private const uint FileSystemPath = 0x80058000;

    public static string? PickFolder(IntPtr owner, string title) => Show(owner, title, folders: true, multiple: false).FirstOrDefault();

    public static IReadOnlyList<string> PickFiles(IntPtr owner, string title) => Show(owner, title, folders: false, multiple: true);

    private static List<string> Show(IntPtr owner, string title, bool folders, bool multiple)
    {
        var result = new List<string>();
        var dialog = (IFileOpenDialog)new FileOpenDialogCom();
        try
        {
            dialog.GetOptions(out var options);
            options |= ForceFileSystem | PathMustExist;
            if (folders) options |= PickFolders;
            if (multiple) options |= AllowMultiple;
            dialog.SetOptions(options);
            dialog.SetTitle(title);
            if (dialog.Show(owner) != 0) return result; // cancelado
            dialog.GetResults(out var items);
            items.GetCount(out var count);
            for (uint index = 0; index < count; index++)
            {
                items.GetItemAt(index, out var item);
                item.GetDisplayName(FileSystemPath, out var path);
                result.Add(path);
                Marshal.ReleaseComObject(item);
            }
            Marshal.ReleaseComObject(items);
        }
        finally
        {
            Marshal.ReleaseComObject(dialog);
        }
        return result;
    }

    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialogCom { }

    [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr types);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, uint placement);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr filter);
        void GetResults(out IShellItemArray items);
        void GetSelectedItems(out IShellItemArray items);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bc, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem item);
        void GetDisplayName(uint form, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("B63EA76D-1F85-456F-A19C-48159EFA858B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemArray
    {
        void BindToHandler(IntPtr bc, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetPropertyStore(uint flags, ref Guid iid, out IntPtr store);
        void GetPropertyDescriptionList(IntPtr key, ref Guid iid, out IntPtr list);
        void GetAttributes(uint flags, uint mask, out uint attributes);
        void GetCount(out uint count);
        void GetItemAt(uint index, out IShellItem item);
    }
}
