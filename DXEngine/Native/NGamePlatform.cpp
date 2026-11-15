#include "Precomp.h"
#include "NGamePlatform.h"
#include "VM/NativeFunc.h"

void NGamePlatform::RegisterFunctions()
{
	RegisterVMNativeFunc_1("GamePlatform", "Instance", &NGamePlatform::Instance, 1350);
	RegisterVMNativeFunc_1("GamePlatform", "Ready", &NGamePlatform::Ready, 1351);
	RegisterVMNativeFunc_0("GamePlatform", "Store", &NGamePlatform::Store, 1352);
	RegisterVMNativeFunc_0("GamePlatform", "ResetAll", &NGamePlatform::ResetAll, 1353);

	RegisterVMNativeFunc_1("GamePlatform", "SupportsUser", &NGamePlatform::SupportsUser, 1355);
	RegisterVMNativeFunc_1("GamePlatform", "SupportsAchievements", &NGamePlatform::SupportsAchievements, 1356);
	RegisterVMNativeFunc_1("GamePlatform", "SupportsStats", &NGamePlatform::SupportsStats, 1357);

	RegisterVMNativeFunc_1("GamePlatform", "UserName", &NGamePlatform::UserName, 1360);
	RegisterVMNativeFunc_1("GamePlatform", "UserState", &NGamePlatform::UserState, 1361);
	RegisterVMNativeFunc_2("GamePlatform", "SetPlayerActionLocation", &NGamePlatform::SetPlayerActionLocation, 1362);
	RegisterVMNativeFunc_2("GamePlatform", "ClearPlayerActionLocation", &NGamePlatform::ClearPlayerActionLocation, 1363);
	RegisterVMNativeFunc_2("GamePlatform", "GetFriendRelationship", &NGamePlatform::GetFriendRelationship, 1364);

	RegisterVMNativeFunc_1("GamePlatform", "AchievementUnlock", &NGamePlatform::AchievementUnlock, 1370);
	RegisterVMNativeFunc_2("GamePlatform", "AchievementQuery", &NGamePlatform::AchievementQuery, 1371);
	RegisterVMNativeFunc_1("GamePlatform", "AchievementClear", &NGamePlatform::AchievementClear, 1372);
	RegisterVMNativeFunc_3("GamePlatform", "AchievementIndicateProgress", &NGamePlatform::AchievementIndicateProgress, 1373);
	RegisterVMNativeFunc_3("GamePlatform", "GetAchievementDisplayAttribute", &NGamePlatform::GetAchievementDisplayAttribute, 1374);
	RegisterVMNativeFunc_2("GamePlatform", "GetAchievementIcon", &NGamePlatform::GetAchievementIcon, 1375);

	RegisterVMNativeFunc_2("GamePlatform", "StatsStoreInt", &NGamePlatform::StatsStoreInt, 1380);
	RegisterVMNativeFunc_2("GamePlatform", "StatsStoreFloat", &NGamePlatform::StatsStoreFloat, 1381);
	RegisterVMNativeFunc_2("GamePlatform", "StatsQueryInt", &NGamePlatform::StatsQueryInt, 1382);
	RegisterVMNativeFunc_2("GamePlatform", "StatsQueryFloat", &NGamePlatform::StatsQueryFloat, 1383);
}

void NGamePlatform::Instance(UObject*& ReturnValue) { ReturnValue = nullptr; }
void NGamePlatform::Ready(UObject* Self, BitfieldBool& ReturnValue) { ReturnValue = false; }
void NGamePlatform::Store(UObject* Self) {}
void NGamePlatform::ResetAll(UObject* Self) {}

void NGamePlatform::SupportsUser(UObject* Self, BitfieldBool& ReturnValue) { ReturnValue = false; }
void NGamePlatform::SupportsAchievements(UObject* Self, BitfieldBool& ReturnValue) { ReturnValue = false; }
void NGamePlatform::SupportsStats(UObject* Self, BitfieldBool& ReturnValue) { ReturnValue = false; }

void NGamePlatform::UserName(UObject* Self, std::string& ReturnValue) { ReturnValue.clear(); }
void NGamePlatform::UserState(UObject* Self, uint8_t& ReturnValue) { ReturnValue = 0; }
void NGamePlatform::SetPlayerActionLocation(UObject* Self, const std::string& Key, const std::string& Value) {}
void NGamePlatform::ClearPlayerActionLocation(UObject* Self, const std::string& Key, const std::string& Value) {}
void NGamePlatform::GetFriendRelationship(UObject* Self, int FriendId, uint8_t& ReturnValue) { ReturnValue = 0; }

void NGamePlatform::AchievementUnlock(UObject* Self, const std::string& Achievement) {}
void NGamePlatform::AchievementQuery(UObject* Self, const std::string& Achievement, BitfieldBool& ReturnValue) { ReturnValue = false; }
void NGamePlatform::AchievementClear(UObject* Self, const std::string& Achievement) {}
void NGamePlatform::AchievementIndicateProgress(UObject* Self, const std::string& Achievement, int Current, int Max) {}
void NGamePlatform::GetAchievementDisplayAttribute(UObject* Self, const std::string& Achievement, const std::string& Key, std::string& ReturnValue) { ReturnValue.clear(); }
void NGamePlatform::GetAchievementIcon(UObject* Self, const std::string& Achievement, UObject*& ReturnValue) { ReturnValue = nullptr; }

void NGamePlatform::StatsStoreInt(UObject* Self, const std::string& Stat, int Value) {}
void NGamePlatform::StatsStoreFloat(UObject* Self, const std::string& Stat, float Value) {}
void NGamePlatform::StatsQueryInt(UObject* Self, const std::string& Stat, int& ReturnValue) { ReturnValue = 0; }
void NGamePlatform::StatsQueryFloat(UObject* Self, const std::string& Stat, float& ReturnValue) { ReturnValue = 0.0f; }
