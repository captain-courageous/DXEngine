#include "Precomp.h"
#include "NConversationList.h"
#include "VM/NativeFunc.h"
#include "Packages/ConSys/UConversationList.h"
#include "Packages/Engine/Actors/UActor.h"

void NConversationList::RegisterFunctions()
{
	RegisterVMNativeFunc_1("ConversationList", "BindConversations", &NConversationList::BindConversations, 2063);
}

void NConversationList::BindConversations(UObject* Self, UObject* bindActor)
{
	auto selfList = UObject::Cast<UConversationList>(Self);
	auto actor = UObject::TryCast<UActor>(bindActor);
	if (selfList && actor)
		selfList->BindConversations(actor);
}
