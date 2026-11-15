#pragma once

#include "UConObject.h"

class UConItem;
class UActor;

class UConversationList : public UConObject
{
public:
	using UConObject::UConObject;

	/// Binds all conversations in this list that match bindActor's BindName or BarkBindName.
	void BindConversations(UActor* bindActor);

	UConItem*& conversations() { return Value<UConItem*>(PropOffsets_ConversationList.conversations); }
	ScriptString& missionDescription() { return Value<ScriptString>(PropOffsets_ConversationList.missionDescription); }
	int& missionNumber() { return Value<int>(PropOffsets_ConversationList.missionNumber); }
};
