#pragma once

#include "Packages/Core/UObject.h"

/// Native interface for Revision's DXOgg.DXOgg Ogg Vorbis music player.
class NDXOgg
{
public:
	static void RegisterFunctions();

	static void SetCurrentOgg(UObject* Self, const std::string& oggFileIntro, const std::string& oggFileLoop, int playPos, uint8_t transition);
	static void SetCurrentOggWithVolume(UObject* Self, const std::string& oggFileIntro, const std::string& oggFileLoop, int playPos, uint8_t transition, float volume);
	static void GetCurrentSongPosition(UObject* Self, float& ReturnValue);
	static void StopPlayback(UObject* Self);
	static void CheckFiles(const std::string& oggFileIntro, const std::string& oggFileLoop, BitfieldBool& ReturnValue);
	static void GetNextOggFileIntro(UObject* Self, std::string& ReturnValue);
	static void GetNextOggFileLoop(UObject* Self, std::string& ReturnValue);
};
