#include "Precomp.h"
#include "NDXOgg.h"
#include "VM/NativeFunc.h"
#include "Engine.h"
#include "Package/PackageManager.h"
#include "Packages/Engine/Subsystems/UDXEngineAudioDevice.h"

void NDXOgg::RegisterFunctions()
{
	RegisterVMNativeFunc_4("DXOgg", "SetCurrentOgg", &NDXOgg::SetCurrentOgg, 0);
	RegisterVMNativeFunc_5("DXOgg", "SetCurrentOggWithVolume", &NDXOgg::SetCurrentOggWithVolume, 0);
	RegisterVMNativeFunc_1("DXOgg", "GetCurrentSongPosition", &NDXOgg::GetCurrentSongPosition, 0);
	RegisterVMNativeFunc_0("DXOgg", "StopPlayback", &NDXOgg::StopPlayback, 0);
	RegisterVMNativeFunc_3("DXOgg", "CheckFiles", &NDXOgg::CheckFiles, 0);
	RegisterVMNativeFunc_1("DXOgg", "GetNextOggFileIntro", &NDXOgg::GetNextOggFileIntro, 0);
	RegisterVMNativeFunc_1("DXOgg", "GetNextOggFileLoop", &NDXOgg::GetNextOggFileLoop, 0);
}

void NDXOgg::SetCurrentOgg(UObject* Self, const std::string& oggFileIntro, const std::string& oggFileLoop, int playPos, uint8_t transition)
{
	SetCurrentOggWithVolume(Self, oggFileIntro, oggFileLoop, playPos, transition, 1.0f);
}

void NDXOgg::SetCurrentOggWithVolume(UObject* Self, const std::string& oggFileIntro, const std::string& oggFileLoop, int playPos, uint8_t transition, float volume)
{
	if (engine && engine->audiodev)
		engine->audiodev->SetDXOgg(oggFileIntro, oggFileLoop, playPos, transition, volume);
}

void NDXOgg::GetCurrentSongPosition(UObject* Self, float& ReturnValue)
{
	ReturnValue = (engine && engine->audiodev) ? engine->audiodev->GetDXOggPosition() : 0.0f;
}

void NDXOgg::StopPlayback(UObject* Self)
{
	if (engine && engine->audiodev)
		engine->audiodev->StopDXOgg();
}

void NDXOgg::CheckFiles(const std::string& oggFileIntro, const std::string& oggFileLoop, BitfieldBool& ReturnValue)
{
	if (!engine || !engine->packages)
	{
		ReturnValue = false;
		return;
	}
	bool introOk = oggFileIntro.empty() || !engine->packages->ResolveOggFile(oggFileIntro).empty();
	bool loopOk = oggFileLoop.empty() || !engine->packages->ResolveOggFile(oggFileLoop).empty();
	ReturnValue = (!oggFileIntro.empty() || !oggFileLoop.empty()) && introOk && loopOk;
}

void NDXOgg::GetNextOggFileIntro(UObject* Self, std::string& ReturnValue)
{
	ReturnValue = (engine && engine->audiodev) ? engine->audiodev->GetNextDXOggIntro() : "";
}

void NDXOgg::GetNextOggFileLoop(UObject* Self, std::string& ReturnValue)
{
	ReturnValue = (engine && engine->audiodev) ? engine->audiodev->GetNextDXOggLoop() : "";
}
