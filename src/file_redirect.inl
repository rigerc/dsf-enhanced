// [Files] Redirect: the game reads a file from another path, as listed by mods in
// <game>\dsf_enhanced\redirect\*.txt (worldlod's map, for one). The game's own files are never
// written, so taking a table out (or the plugin) gives the game its own file back.
//
// A table line is "game path|replacement[|limits]", both paths relative to the game folder; empty
// lines and lines starting with '#' are skipped. The game path matches without case, with '/' or
// '\', with or without a leading ".\" or the game folder. The file layer resolves device paths
// ("TEXT:global.fchunk") before it calls CreateFileA, so a table names the file itself
// ("Locale\English\global.fchunk"). limits is a comma list of [Limits] keys the replacement needs
// (ResourceArenaExtraNodes, PendingResourceReferences, SubmodelTableExtraNodes): it is opened only
// once each of those patches is in, else the game's own file is (logged). A replacement that is
// missing at start, or won't open, also leaves the game's file. Only opens for reading are
// redirected. A game path listed twice keeps its first line (tables are read in name order).
//
// The hook is Driver.exe's import of KERNEL32 CreateFileA, not one call site, so it sees the
// file layer's open (0x0085AC1E: the spool readers, the world archive among them), its file
// check (0x0085B030) and every other open. dsfforza.asi patches the call at 0x0085AC1E for the
// car manager's GUI copies; from the version with "archive.redirect_chain" among its
// capabilities it passes every other name on through this import, so both plugins redirect in
// either load order. An older dsfforza.asi calls KERNEL32 itself there: its own files are still
// redirected, but files listed here and opened at that site are not, and the game reads its own.

using CreateFileAFn = HANDLE(WINAPI*)(LPCSTR, DWORD, DWORD, LPSECURITY_ATTRIBUTES, DWORD, DWORD, HANDLE);

constexpr unsigned kNeedResourceArena = 1;
constexpr unsigned kNeedPendingReferences = 2;
constexpr unsigned kNeedSubmodelTable = 4;

struct FileRedirect
{
    char from[MAX_PATH];  // normalised game-relative path
    char to[MAX_PATH];    // full path of the replacement
    char table[64];       // the table it came from, for the log
    unsigned needs;       // kNeed* bits
    volatile LONG fallback_logged;
    volatile LONG opened;
};

CreateFileAFn g_create_file_a = nullptr;
std::vector<FileRedirect> g_file_redirects;  // filled before the game runs, read-only after
char g_file_redirect_base[MAX_PATH] = {};    // game folder, lower-case, trailing backslash
HANDLE g_file_redirect_patches_done = nullptr;

// Lower-case, '/' -> '\', without the game folder or a leading ".\".
void FileRedirectKey(const char* in, char* out, size_t size)
{
    char tmp[MAX_PATH] = {};
    size_t i = 0;
    for (; in[i] != '\0' && i + 1 < sizeof(tmp); ++i) {
        const char c = in[i] == '/' ? '\\' : in[i];
        tmp[i] = (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c;
    }
    tmp[i] = '\0';
    const char* s = tmp;
    const size_t base = std::strlen(g_file_redirect_base);
    if (base != 0 && std::strncmp(s, g_file_redirect_base, base) == 0) {
        s += base;
    }
    while (s[0] == '.' && s[1] == '\\') {
        s += 2;
    }
    strncpy_s(out, size, s, _TRUNCATE);
}

char* TrimSpaces(char* s)
{
    while (*s == ' ' || *s == '\t') {
        ++s;
    }
    char* end = s + std::strlen(s);
    while (end > s && (end[-1] == ' ' || end[-1] == '\t')) {
        *--end = '\0';
    }
    return s;
}

// The kNeed* bits of a comma list of [Limits] keys; false for a key this plugin doesn't know.
bool ParseRedirectNeeds(char* list, unsigned* needs, const char** unknown)
{
    *needs = 0;
    for (char* context = nullptr; char* token = strtok_s(list, ",", &context); list = nullptr) {
        const char* key = TrimSpaces(token);
        if (*key == '\0') {
            continue;
        }
        if (_stricmp(key, "ResourceArenaExtraNodes") == 0) {
            *needs |= kNeedResourceArena;
        } else if (_stricmp(key, "PendingResourceReferences") == 0) {
            *needs |= kNeedPendingReferences;
        } else if (_stricmp(key, "SubmodelTableExtraNodes") == 0) {
            *needs |= kNeedSubmodelTable;
        } else {
            *unknown = key;
            return false;
        }
    }
    return true;
}

const FileRedirect* FindFileRedirect(const char* name)
{
    if (name == nullptr || g_file_redirects.empty()) {
        return nullptr;
    }
    char key[MAX_PATH] = {};
    FileRedirectKey(name, key, sizeof(key));
    for (const FileRedirect& r : g_file_redirects) {
        if (std::strcmp(key, r.from) == 0) {
            return &r;
        }
    }
    return nullptr;
}

void LoadRedirectTable(const char* game, const char* path, const char* table)
{
    FILE* file = nullptr;
    if (fopen_s(&file, path, "r") != 0 || file == nullptr) {
        Log("FileRedirect: can't read %s", path);
        return;
    }
    char line[3 * MAX_PATH] = {};
    while (std::fgets(line, sizeof(line), file) != nullptr) {
        line[std::strcspn(line, "\r\n")] = '\0';
        char* text = TrimSpaces(line);
        if (*text == '\0' || *text == '#') {
            continue;
        }
        char* to = std::strchr(text, '|');
        char* limits = to != nullptr ? std::strchr(to + 1, '|') : nullptr;
        if (to != nullptr) {
            *to++ = '\0';
        }
        if (limits != nullptr) {
            *limits++ = '\0';
        }
        if (to == nullptr || *TrimSpaces(text) == '\0' || *TrimSpaces(to) == '\0') {
            Log("FileRedirect: %s: '%s' is not \"game path|replacement\"; left out", table, text);
            continue;
        }
        FileRedirect r = {};
        FileRedirectKey(TrimSpaces(text), r.from, sizeof(r.from));
        std::snprintf(r.to, sizeof(r.to), "%s%s", game, TrimSpaces(to));
        strncpy_s(r.table, sizeof(r.table), table, _TRUNCATE);
        const char* unknown = nullptr;
        if (limits != nullptr && !ParseRedirectNeeds(limits, &r.needs, &unknown)) {
            Log("FileRedirect: %s: %s needs [Limits] %s, which this plugin doesn't have; left out", table, r.from, unknown);
            continue;
        }
        if (FindFileRedirect(r.from) != nullptr) {
            Log("FileRedirect: %s: %s is listed already; this line is left out", table, r.from);
            continue;
        }
        if (GetFileAttributesA(r.to) == INVALID_FILE_ATTRIBUTES) {
            Log("FileRedirect: %s: %s -> %s: no such file; left out", table, r.from, r.to);
            continue;
        }
        Log("FileRedirect: %s: %s -> %s%s", table, r.from, TrimSpaces(to), r.needs != 0 ? " (needs [Limits])" : "");
        g_file_redirects.push_back(r);
    }
    std::fclose(file);
}

// The kNeed* bits the replacement needs that aren't in; waits for ApplyPatches first (it runs
// on the init thread, and the game can open a file before it's done).
unsigned MissingRedirectNeeds(unsigned needs)
{
    if (needs == 0) {
        return 0;
    }
    if (g_file_redirect_patches_done != nullptr) {
        WaitForSingleObject(g_file_redirect_patches_done, 30000);
    }
    unsigned missing = 0;
    if ((needs & kNeedResourceArena) != 0 && !g_resource_arena_patch_applied) {
        missing |= kNeedResourceArena;
    }
    if ((needs & kNeedPendingReferences) != 0 && !g_pending_reference_patch_applied) {
        missing |= kNeedPendingReferences;
    }
    if ((needs & kNeedSubmodelTable) != 0 && !g_submodel_table_patch_applied) {
        missing |= kNeedSubmodelTable;
    }
    return missing;
}

HANDLE WINAPI ProxyCreateFileA(
    LPCSTR name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES security, DWORD disposition, DWORD flags,
    HANDLE template_file
)
{
    auto* r = const_cast<FileRedirect*>(FindFileRedirect(name));
    const bool reading = disposition == OPEN_EXISTING && (access & (GENERIC_WRITE | GENERIC_ALL)) == 0;
    if (r != nullptr && reading) {
        const unsigned missing = MissingRedirectNeeds(r->needs);
        if (missing != 0) {
            if (InterlockedExchange(&r->fallback_logged, 1) == 0) {
                Log(
                    "FileRedirect: %s stays the game's own: [Limits]%s%s%s not in effect (off in dsf_enhanced.ini, "
                    "or not patched: see above)",
                    name,
                    (missing & kNeedResourceArena) != 0 ? " ResourceArenaExtraNodes" : "",
                    (missing & kNeedPendingReferences) != 0 ? " PendingResourceReferences" : "",
                    (missing & kNeedSubmodelTable) != 0 ? " SubmodelTableExtraNodes" : ""
                );
            }
        } else {
            const HANDLE handle = g_create_file_a(r->to, access, share, security, disposition, flags, template_file);
            if (handle != INVALID_HANDLE_VALUE) {
                if (InterlockedIncrement(&r->opened) <= 8) {
                    Log("FileRedirect: '%s' opened as %s", name, r->to);
                }
                return handle;
            }
            const DWORD error = GetLastError();
            if (InterlockedExchange(&r->fallback_logged, 1) == 0) {
                Log("FileRedirect: %s won't open (error %lu); '%s' is the game's own", r->to, error, name);
            }
        }
    }
    return g_create_file_a(name, access, share, security, disposition, flags, template_file);
}

// Reads the tables and hooks the import when they list a file. Runs in DllMain.
void ApplyFileRedirects(const ModuleRange& range)
{
    if (!g_file_redirect) {
        Log("FileRedirect: [Files] Redirect=0; the game's own files are used");
        return;
    }
    char game[MAX_PATH] = {};
    BuildGamePath(game, MAX_PATH, "");
    FileRedirectKey(game, g_file_redirect_base, sizeof(g_file_redirect_base));  // nothing stripped yet: the base is empty
    char pattern[MAX_PATH] = {};
    std::snprintf(pattern, sizeof(pattern), "%sdsf_enhanced\\redirect\\*.txt", game);
    WIN32_FIND_DATAA found = {};
    const HANDLE search = FindFirstFileA(pattern, &found);
    if (search == INVALID_HANDLE_VALUE) {
        return;  // no tables: nothing to hook
    }
    struct TableName
    {
        char name[MAX_PATH];
    };
    std::vector<TableName> tables;
    do {
        if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
            TableName t = {};
            strncpy_s(t.name, sizeof(t.name), found.cFileName, _TRUNCATE);
            tables.push_back(t);
        }
    } while (FindNextFileA(search, &found));
    FindClose(search);
    std::sort(tables.begin(), tables.end(), [](const TableName& a, const TableName& b) {
        return _stricmp(a.name, b.name) < 0;
    });
    for (const TableName& table : tables) {
        char path[MAX_PATH] = {};
        std::snprintf(path, sizeof(path), "%sdsf_enhanced\\redirect\\%s", game, table.name);
        LoadRedirectTable(game, path, table.name);
    }
    if (g_file_redirects.empty()) {
        return;
    }
    g_file_redirect_patches_done = CreateEventA(nullptr, TRUE, FALSE, nullptr);
    void* original = nullptr;
    if (!PatchImportByName(range, "KERNEL32.dll", "CreateFileA", reinterpret_cast<void*>(&ProxyCreateFileA), &original)) {
        Log("FileRedirect: Driver.exe's CreateFileA import not found; the game's own files are used");
        g_file_redirects.clear();
        return;
    }
    g_create_file_a = reinterpret_cast<CreateFileAFn>(original);
    Log("FileRedirect: CreateFileA import -> 0x%p; %u files redirected", &ProxyCreateFileA,
        static_cast<unsigned>(g_file_redirects.size()));
}

// ApplyPatches is done: the limits a redirect needs are in now or won't be.
void FileRedirectPatchesDone()
{
    if (g_file_redirect_patches_done != nullptr) {
        SetEvent(g_file_redirect_patches_done);
    }
}
