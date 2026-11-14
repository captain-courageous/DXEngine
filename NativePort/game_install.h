#pragma once
#include "Precomp.h"
#include "UE1GameDatabase.h"
#include "Package/IniFile.h"
#include <filesystem>
#include <stdexcept>

namespace fs = std::filesystem;

inline fs::path DefaultDeusExInstall(const fs::path& app, const fs::path& remembered)
{
    const auto bundled = app/"Contents/Resources/GameData";
    if (fs::is_directory(bundled)) return bundled;
    const auto adjacent = app.parent_path()/"Put game files here";
    return fs::is_directory(adjacent) ? adjacent : remembered;
}

inline fs::path ValidateDeusExInstall(fs::path assets)
{
    if (assets.filename() == "System") assets = assets.parent_path();
    assets = fs::canonical(assets);
    for (const char* file : {"System/DeusEx.exe", "System/Default.ini", "System/DefUser.ini",
         "System/Core.u", "System/Engine.u", "System/DeusEx.u", "System/DeusExUI.u",
         "Maps/Entry.dx", "Maps/01_NYC_UNATCOIsland.dx"}) {
        if (!fs::is_regular_file(assets/file) || fs::file_size(assets/file) == 0)
            throw std::runtime_error(std::string("Missing game file: ") + file +
                ". Select the complete, installed Deus Ex GOTY folder.");
    }
    for (const auto& item : {std::pair{"Textures", ".utx"}, {"Sounds", ".uax"}, {"Music", ".umx"}}) {
        bool found = false;
        if (fs::is_directory(assets/item.first))
            for (const auto& entry : fs::directory_iterator(assets/item.first))
                if (entry.is_regular_file() && entry.path().extension() == item.second && entry.file_size() > 0)
                    found = true;
        if (!found) throw std::runtime_error(std::string("Missing game data in ") + item.first + ". Select the complete installation.");
    }
    if (FindUE1GameInPath(assets.string()).first != KnownUE1Games::DEUS_EX_1112fm)
        throw std::runtime_error("This installation is not a recognised Deus Ex GOTY 1.112fm release. Restore the original System/DeusEx.exe if a replacement launcher is installed.");
    return assets;
}

inline void PrepareDeusExInstall(const fs::path& selected, const fs::path& game)
{
    const auto assets = ValidateDeusExInstall(selected);
    if (assets == fs::weakly_canonical(game))
        throw std::runtime_error("Select your original game installation, not the native app's settings folder.");
    for (const char* folder : {"System", "Save", "Cache"}) {
        if (fs::is_symlink(game/folder)) throw std::runtime_error("Expected a local settings folder: " + (game/folder).string());
        fs::create_directories(game/folder);
    }
    auto link = [](const fs::path& source, const fs::path& target) {
        if (fs::is_symlink(target)) {
            if (fs::read_symlink(target) == source) return;
            fs::remove(target);
        } else if (fs::exists(target)) {
            throw std::runtime_error("Cannot replace existing game data: " + target.string());
        }
        fs::create_symlink(source, target);
    };
    for (const char* folder : {"Maps", "Music", "Sounds", "Textures"}) link(assets/folder, game/folder);
    // Remove only links left by the previous installation; preserve settings and saves.
    for (const auto& entry : fs::directory_iterator(game/"System"))
        if (entry.is_symlink() && !fs::exists(assets/"System"/entry.path().filename())) fs::remove(entry.path());
    for (const auto& entry : fs::directory_iterator(assets/"System")) {
        if (!entry.is_regular_file()) continue;
        auto target = game/"System"/entry.path().filename();
        if (entry.path().extension() == ".ini") {
            if (fs::is_symlink(target)) throw std::runtime_error("Settings must be local files: " + target.string());
            if (!fs::exists(target)) fs::copy_file(entry.path(), target);
        } else if (entry.path().extension() == ".u" || entry.path().extension() == ".int" || entry.path().filename() == "DeusEx.exe") {
            link(entry.path(), target);
        }
    }
    for (const auto& [file, clientSection] : {
        std::pair{"System/SE-DeusEx.ini", "Engine.SurrealClient"},
        std::pair{"System/DXE-DeusEx.ini", "Engine.DXEngineClient"}
    }) {
        auto config = game/file;
        const bool fresh = !fs::exists(config);
        IniFile ini((fresh ? game/"System/Default.ini" : config).string());
        ini.SetValues("Core.System", "Paths", {"../System/*.u", "../Maps/*.dx", "../Textures/*.utx", "../Sounds/*.uax", "../Music/*.umx"});
        ini.SetValue("Core.System", "SavePath", "../Save");
        ini.SetValue("Core.System", "CachePath", "../Cache");
        if (fresh) {
            ini.SetValue(clientSection, "StartupFullscreen", "True");
            ini.SetValue(clientSection, "WindowedViewportX", "1280");
            ini.SetValue(clientSection, "WindowedViewportY", "720");
            ini.SetValue(clientSection, "FullscreenViewportX", "0");
            ini.SetValue(clientSection, "FullscreenViewportY", "0");
        }
        if (fresh || ini.IsModified()) ini.SaveTo(config.string());
    }
}
