#pragma once

#include "Packages/Core/UObject.h"

/// Native interface for Revision's EngineI.GamePlatform (indices 1350..1383).
class NGamePlatform
{
public:
	static void RegisterFunctions();

	static void Instance(UObject*& ReturnValue);
	static void Ready(UObject* Self, BitfieldBool& ReturnValue);
	static void Store(UObject* Self);
	static void ResetAll(UObject* Self);

	static void SupportsUser(UObject* Self, BitfieldBool& ReturnValue);
	static void SupportsAchievements(UObject* Self, BitfieldBool& ReturnValue);
	static void SupportsStats(UObject* Self, BitfieldBool& ReturnValue);

	static void UserName(UObject* Self, std::string& ReturnValue);
	static void UserState(UObject* Self, uint8_t& ReturnValue);
	static void SetPlayerActionLocation(UObject* Self, const std::string& Key, const std::string& Value);
	static void ClearPlayerActionLocation(UObject* Self, const std::string& Key, const std::string& Value);
	static void GetFriendRelationship(UObject* Self, int FriendId, uint8_t& ReturnValue);

	static void AchievementUnlock(UObject* Self, const std::string& Achievement);
	static void AchievementQuery(UObject* Self, const std::string& Achievement, BitfieldBool& ReturnValue);
	static void AchievementClear(UObject* Self, const std::string& Achievement);
	static void AchievementIndicateProgress(UObject* Self, const std::string& Achievement, int Current, int Max);
	static void GetAchievementDisplayAttribute(UObject* Self, const std::string& Achievement, const std::string& Key, std::string& ReturnValue);
	static void GetAchievementIcon(UObject* Self, const std::string& Achievement, UObject*& ReturnValue);

	static void StatsStoreInt(UObject* Self, const std::string& Stat, int Value);
	static void StatsStoreFloat(UObject* Self, const std::string& Stat, float Value);
	static void StatsQueryInt(UObject* Self, const std::string& Stat, int& ReturnValue);
	static void StatsQueryFloat(UObject* Self, const std::string& Stat, float& ReturnValue);
};
