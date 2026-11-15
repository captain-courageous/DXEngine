#pragma once

#include "Packages/Core/UObject.h"

class NConversationList
{
public:
	static void RegisterFunctions();

	static void BindConversations(UObject* Self, UObject* bindActor);
};
