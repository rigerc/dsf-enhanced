// [Files] Redirect (src/file_redirect.inl), outside the game: this exe stands in for Driver.exe.
// It writes a game folder layout beside itself (tables in dsf_enhanced\redirect\, the files they
// name), loads dsf_enhanced.asi from that folder (the hook goes on this exe's CreateFileA import,
// as on Driver.exe's) and opens files through the import:
//   - a listed path, in any case, with '/', ".\" or the full folder, reads the replacement;
//   - an open for writing, or of a path not listed, reads the file itself;
//   - a line needing [Limits] patches that aren't in (none apply to this exe) leaves the file itself;
//   - a line whose replacement is missing, or that names an unknown limit, is left out.
// Usage: file_redirect_test.exe <dsf_enhanced.asi>; build.ps1 runs it.
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace {

std::string g_dir;  // this exe's folder, trailing backslash
int g_failures = 0;

void WriteFile(const std::string& rel, const char* text)
{
    const std::string path = g_dir + rel;
    for (size_t i = g_dir.size(); i < path.size(); ++i) {
        if (path[i] == '\\') {
            CreateDirectoryA(path.substr(0, i).c_str(), nullptr);
        }
    }
    FILE* f = nullptr;
    fopen_s(&f, path.c_str(), "wb");
    std::fputs(text, f);
    std::fclose(f);
}

// Reads what opening name through the import gives (access: GENERIC_READ or GENERIC_READ|GENERIC_WRITE).
std::string Open(const std::string& name, DWORD access = GENERIC_READ)
{
    const HANDLE h = CreateFileA(name.c_str(), access, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) {
        return "<no file>";
    }
    char buffer[64] = {};
    DWORD read = 0;
    ReadFile(h, buffer, sizeof(buffer) - 1, &read, nullptr);
    CloseHandle(h);
    return std::string(buffer, read);
}

void Expect(const char* what, const std::string& got, const char* want)
{
    if (got != want) {
        std::printf("FAIL: %s: got '%s', want '%s'\n", what, got.c_str(), want);
        ++g_failures;
    }
}

} // namespace

int main(int argc, char** argv)
{
    if (argc != 2) {
        std::printf("usage: file_redirect_test <dsf_enhanced.asi>\n");
        return 2;
    }
    char exe[MAX_PATH] = {};
    GetModuleFileNameA(nullptr, exe, MAX_PATH);
    g_dir = exe;
    g_dir.resize(g_dir.rfind('\\') + 1);
    SetCurrentDirectoryA(g_dir.c_str());  // the game runs in its folder: relative names start there

    WriteFile("Install\\world.dngc", "stock world");
    WriteFile("Install\\gui.sp", "stock gui");
    WriteFile("Install\\other.sp", "stock other");
    WriteFile("Install\\missing.sp", "stock missing");
    WriteFile("Install\\unknown.sp", "stock unknown");
    WriteFile("mod\\world.dngc", "mod world");
    WriteFile("mod\\gui.sp", "mod gui");
    WriteFile("mod\\unknown.sp", "mod unknown");
    WriteFile(
        "dsf_enhanced\\redirect\\a.txt",
        "# a comment, then an empty line\n"
        "\n"
        "Install/World.dngc|mod\\world.dngc\n"
        "Install\\other.sp | mod\\gui.sp | SubmodelTableExtraNodes, PendingResourceReferences\n"
        "Install\\missing.sp|mod\\missing.sp\n"
        "Install\\unknown.sp|mod\\unknown.sp|NoSuchLimit\n"
        "not a line\n"
    );
    WriteFile("dsf_enhanced\\redirect\\b.txt", "install\\world.dngc|mod\\gui.sp\nInstall\\gui.sp|mod\\gui.sp\n");
    // Only the redirect: every other patch looks for Driver.exe's code and would just log.
    WriteFile("dsf_enhanced.ini", "[General]\nLog=1\n[Files]\nRedirect=1\n");
    DeleteFileA((g_dir + "dsf_enhanced.log").c_str());

    Expect("before the plugin", Open("Install\\world.dngc"), "stock world");
    const std::string asi = g_dir + "dsf_enhanced.asi";
    if (!CopyFileA(argv[1], asi.c_str(), FALSE) || LoadLibraryA(asi.c_str()) == nullptr) {
        std::printf("FAIL: could not load %s (error %lu)\n", argv[1], GetLastError());
        return 1;
    }

    Expect("listed path", Open("Install\\world.dngc"), "mod world");
    Expect("other case, slashes", Open("INSTALL/WORLD.DNGC"), "mod world");
    Expect("leading .\\", Open(".\\Install\\world.dngc"), "mod world");
    Expect("full path", Open(g_dir + "Install\\world.dngc"), "mod world");
    Expect("second table", Open("Install\\gui.sp"), "mod gui");
    Expect("for writing", Open("Install\\world.dngc", GENERIC_READ | GENERIC_WRITE), "stock world");
    Expect("needs limits not in", Open("Install\\other.sp"), "stock other");
    Expect("replacement missing", Open("Install\\missing.sp"), "stock missing");
    Expect("unknown limit", Open("Install\\unknown.sp"), "stock unknown");
    Expect("not listed", Open("mod\\unknown.sp"), "mod unknown");

    std::string log;
    {
        FILE* f = nullptr;
        fopen_s(&f, (g_dir + "dsf_enhanced.log").c_str(), "rb");
        char buffer[4096];
        for (size_t n; f != nullptr && (n = std::fread(buffer, 1, sizeof(buffer), f)) != 0;) {
            log.append(buffer, n);
        }
        if (f != nullptr) {
            std::fclose(f);
        }
    }
    const char* lines[] = {
        "a.txt: 'not a line' is not",
        "a.txt: install\\missing.sp -> ",
        "doesn't have; left out",
        "b.txt: install\\world.dngc is listed already",
        "CreateFileA import -> ",
        "3 files redirected",
        "Install\\other.sp stays the game's own: [Limits] PendingResourceReferences SubmodelTableExtraNodes",
    };
    for (const char* line : lines) {
        if (log.find(line) == std::string::npos) {
            std::printf("FAIL: the log lacks \"%s\"\n", line);
            ++g_failures;
        }
    }
    if (g_failures != 0) {
        std::printf("--- dsf_enhanced.log\n%s", log.c_str());
        return 1;
    }
    std::printf("file_redirect_test: ok\n");
    // The plugin's thread runs on; leave without waiting for it.
    std::fflush(stdout);
    TerminateProcess(GetCurrentProcess(), 0);
    return 0;
}
