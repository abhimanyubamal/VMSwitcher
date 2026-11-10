// Minimal SQLite wrapper over winsqlite3.dll, the SQLite engine that ships inside
// Windows 10 / Windows Server 2016 and later. No third-party DLLs are needed.
// Written in C# 5 so it compiles with the in-box csc.exe and with PowerShell 5.1 Add-Type.
using System;
using System.Data;
using System.Runtime.InteropServices;
using System.Text;

namespace VMSwitcher
{
    public sealed class SqliteException : Exception
    {
        public int Code { get; private set; }
        public SqliteException(int code, string message) : base(message) { Code = code; }
    }

    public sealed class SqliteDb : IDisposable
    {
        const string Lib = "winsqlite3.dll";
        const int SQLITE_OK = 0, SQLITE_ROW = 100, SQLITE_DONE = 101;
        const int T_INTEGER = 1, T_FLOAT = 2, T_TEXT = 3, T_BLOB = 4, T_NULL = 5;
        const int OPEN_READWRITE = 0x2, OPEN_CREATE = 0x4, OPEN_FULLMUTEX = 0x10000;
        static readonly IntPtr TRANSIENT = new IntPtr(-1);

        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, IntPtr sql, int nByte, out IntPtr stmt, out IntPtr tail);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_name(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_type(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern long sqlite3_column_int64(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern double sqlite3_column_double(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr stmt, int col);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_parameter_count(IntPtr stmt);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_int64(IntPtr stmt, int idx, long val);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_double(IntPtr stmt, int idx, double val);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_text(IntPtr stmt, int idx, byte[] val, int n, IntPtr destructor);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_null(IntPtr stmt, int idx);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_changes(IntPtr db);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern long sqlite3_last_insert_rowid(IntPtr db);
        [DllImport(Lib, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_libversion();

        IntPtr _db;
        readonly object _gate = new object();
        public string Path { get; private set; }

        public static string EngineVersion { get { return Utf8(sqlite3_libversion(), -1); } }

        public SqliteDb(string path, int busyTimeoutMs)
        {
            Path = path;
            int rc = sqlite3_open_v2(Z(path), out _db, OPEN_READWRITE | OPEN_CREATE | OPEN_FULLMUTEX, IntPtr.Zero);
            if (rc != SQLITE_OK)
            {
                string msg = _db != IntPtr.Zero ? Utf8(sqlite3_errmsg(_db), -1) : "open failed";
                if (_db != IntPtr.Zero) sqlite3_close_v2(_db);
                _db = IntPtr.Zero;
                throw new SqliteException(rc, "Cannot open database '" + path + "': " + msg);
            }
            sqlite3_busy_timeout(_db, busyTimeoutMs);
        }

        /// Runs one or more statements that return no rows (schema scripts, pragmas).
        public void ExecScript(string sql)
        {
            lock (_gate)
            {
                byte[] bytes = Z(sql);
                GCHandle h = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                try
                {
                    IntPtr start = h.AddrOfPinnedObject();
                    IntPtr cur = start;
                    long end = start.ToInt64() + bytes.Length - 1;
                    while (cur.ToInt64() < end)
                    {
                        IntPtr stmt, tail;
                        int rc = sqlite3_prepare_v2(_db, cur, -1, out stmt, out tail);
                        Check(rc);
                        if (stmt == IntPtr.Zero) break; // only whitespace or comments left
                        try
                        {
                            while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) { }
                            if (rc != SQLITE_DONE) Check(rc);
                        }
                        finally { sqlite3_finalize(stmt); }
                        cur = tail;
                    }
                }
                finally { h.Free(); }
            }
        }

        /// Runs one statement with ? parameters. Returns the number of changed rows.
        public int Execute(string sql, params object[] args)
        {
            lock (_gate)
            {
                IntPtr stmt = Prepare(sql, args);
                try
                {
                    int rc;
                    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) { }
                    if (rc != SQLITE_DONE) Check(rc);
                    return sqlite3_changes(_db);
                }
                finally { sqlite3_finalize(stmt); }
            }
        }

        /// Runs an INSERT and returns the new row id.
        public long Insert(string sql, params object[] args)
        {
            lock (_gate)
            {
                Execute(sql, args);
                return sqlite3_last_insert_rowid(_db);
            }
        }

        /// Runs a SELECT and returns all rows as a DataTable (columns typed as object).
        public DataTable Query(string sql, params object[] args)
        {
            lock (_gate)
            {
                IntPtr stmt = Prepare(sql, args);
                try
                {
                    var table = new DataTable();
                    int cols = sqlite3_column_count(stmt);
                    for (int i = 0; i < cols; i++)
                    {
                        string name = Utf8(sqlite3_column_name(stmt, i), -1);
                        string unique = name; int n = 2;
                        while (table.Columns.Contains(unique)) unique = name + (n++);
                        table.Columns.Add(unique, typeof(object));
                    }
                    int rc;
                    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW)
                    {
                        object[] values = new object[cols];
                        for (int i = 0; i < cols; i++) values[i] = ReadColumn(stmt, i);
                        table.Rows.Add(values);
                    }
                    if (rc != SQLITE_DONE) Check(rc);
                    return table;
                }
                finally { sqlite3_finalize(stmt); }
            }
        }

        /// Returns the first column of the first row, or null.
        public object Scalar(string sql, params object[] args)
        {
            DataTable t = Query(sql, args);
            if (t.Rows.Count == 0 || t.Columns.Count == 0) return null;
            object v = t.Rows[0][0];
            return v == DBNull.Value ? null : v;
        }

        public void Dispose()
        {
            lock (_gate)
            {
                if (_db != IntPtr.Zero) { sqlite3_close_v2(_db); _db = IntPtr.Zero; }
            }
        }

        IntPtr Prepare(string sql, object[] args)
        {
            if (_db == IntPtr.Zero) throw new ObjectDisposedException("SqliteDb");
            byte[] bytes = Z(sql);
            GCHandle h = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            IntPtr stmt, tail;
            try { Check(sqlite3_prepare_v2(_db, h.AddrOfPinnedObject(), -1, out stmt, out tail)); }
            finally { h.Free(); }
            int expected = sqlite3_bind_parameter_count(stmt);
            int given = args == null ? 0 : args.Length;
            if (expected != given)
            {
                sqlite3_finalize(stmt);
                throw new ArgumentException("SQL expects " + expected + " parameters but got " + given + ": " + sql);
            }
            for (int i = 0; i < given; i++) Bind(stmt, i + 1, args[i]);
            return stmt;
        }

        void Bind(IntPtr stmt, int idx, object v)
        {
            v = Unwrap(v);
            int rc;
            if (v == null || v == DBNull.Value) rc = sqlite3_bind_null(stmt, idx);
            else if (v is bool) rc = sqlite3_bind_int64(stmt, idx, (bool)v ? 1 : 0);
            else if (v is int || v is long || v is short || v is byte || v is uint || v is ushort || v is sbyte)
                rc = sqlite3_bind_int64(stmt, idx, Convert.ToInt64(v));
            else if (v is double || v is float || v is decimal) rc = sqlite3_bind_double(stmt, idx, Convert.ToDouble(v));
            else if (v is DateTime) { byte[] b = Encoding.UTF8.GetBytes(((DateTime)v).ToString("yyyy-MM-dd HH:mm:ss")); rc = sqlite3_bind_text(stmt, idx, b, b.Length, TRANSIENT); }
            else { byte[] b = Encoding.UTF8.GetBytes(v.ToString()); rc = sqlite3_bind_text(stmt, idx, b, b.Length, TRANSIENT); }
            if (rc != SQLITE_OK) { sqlite3_finalize(stmt); Check(rc); }
        }

        static object Unwrap(object v)
        {
            // PowerShell may hand us PSObject wrappers; unwrap without referencing System.Management.Automation.
            while (v != null && v.GetType().FullName == "System.Management.Automation.PSObject")
                v = v.GetType().GetProperty("BaseObject").GetValue(v, null);
            return v;
        }

        static object ReadColumn(IntPtr stmt, int i)
        {
            switch (sqlite3_column_type(stmt, i))
            {
                case T_INTEGER: return sqlite3_column_int64(stmt, i);
                case T_FLOAT: return sqlite3_column_double(stmt, i);
                case T_NULL: return DBNull.Value;
                case T_BLOB: return "(blob)";
                default:
                    {
                        IntPtr p = sqlite3_column_text(stmt, i);
                        int len = sqlite3_column_bytes(stmt, i);
                        return Utf8(p, len);
                    }
            }
        }

        void Check(int rc)
        {
            if (rc == SQLITE_OK || rc == SQLITE_ROW || rc == SQLITE_DONE) return;
            throw new SqliteException(rc, "SQLite error " + rc + ": " + Utf8(sqlite3_errmsg(_db), -1));
        }

        static byte[] Z(string s)
        {
            byte[] b = Encoding.UTF8.GetBytes(s ?? "");
            byte[] z = new byte[b.Length + 1];
            Buffer.BlockCopy(b, 0, z, 0, b.Length);
            return z;
        }

        static string Utf8(IntPtr p, int len)
        {
            if (p == IntPtr.Zero) return null;
            if (len < 0) { len = 0; while (Marshal.ReadByte(p, len) != 0) len++; }
            if (len == 0) return "";
            byte[] b = new byte[len];
            Marshal.Copy(p, b, 0, len);
            return Encoding.UTF8.GetString(b);
        }
    }
}
