let psnsm = require("%scripts/social/psnSessionManager/psnSessionManagerApi.nut")
let psnNotify = require("%sonyLib/notifications.nut")
// local base64 = require("base64")

let { addListenersWithoutEnv } = require("%sqStdLibs/helpers/subscriptions.nut")
let { isEmpty, copy } = require("%sqStdLibs/helpers/u.nut")

let PSN_SESSION_TYPE = {
  SKIRMISH = "skirmish"
  SQUAD = "squad"
}

/*
[sessionId] = {
  sType = [PSN_SESSION_TYPE]
  data = [getSessionData()]
}
*/
let createdSessionData = persist("createdSessionData", @() ::Watched({}))
let dumpSessionData = function(sessionId, sType, pushContextId, sessionData) {
   createdSessionData.mutate(@(v) v[sessionId] <- {
      sType = sType
      pushContextId = pushContextId
      data = copy(sessionData)
    })
}

// { [PSN_SESSION_TYPE] = data }
let pendingSessions = persist("pendingSessions", @() ::Watched({}))

//[sessionId] = {activityId, isSpectator}
let postponedInvitations = persist("postponedInvitations", @() ::Watched([]))

let getLocalizedTextInfo = function(locIdsArray) {
  let textsData = ::g_localization.getFilledFeedTextByLang(locIdsArray)
  let res = {}
  foreach (block in textsData)
    res[block.abbreviation] <- block.text

  return res
}

let getCustomDataByType = @(sType) sType == PSN_SESSION_TYPE.SKIRMISH
  ? [
      {roomId = ::SessionLobby.roomId}
      {inviterUid = ::my_user_id_str}
      {sType = PSN_SESSION_TYPE.SKIRMISH}
    ]
  : sType == PSN_SESSION_TYPE.SQUAD
    ? [
        {squadId = ::my_user_id_str}
        {leaderId = ::g_squad_manager.getLeaderUid()}
        {sType = PSN_SESSION_TYPE.SQUAD}
      ]
    : []

// TODO: replace with normal base64 encode/decode
// Just in time of psn tests.
let BASE64_SEPARATOR = "/"
let BASE64_GARBAGE = "+"
let encodeDataToBase64Like = function(data) {
  let res = []
  foreach (block in data) {
    foreach (key, val in block)
      res.append(val)
  }

  local base64Str = BASE64_SEPARATOR.join(res)
  let isEq4 = base64Str.len() % 4

  if (isEq4) {
    base64Str = "".concat(base64Str, BASE64_SEPARATOR)
    for (local i = 0; i < (3 - isEq4); i++)
      base64Str = "".concat(base64Str, BASE64_GARBAGE)
  }

  //It is basically string with
  //  '/' is delimiter
  //  '+' is just a garbage for ending %4 length string
  return base64Str
}

let decodeBase64LikeToArray = function(str) {
  let params = str.split(BASE64_SEPARATOR)
  if (params.top().indexof(BASE64_GARBAGE) != null || isEmpty(params.top()))
    params.remove(params.len() - 1)

  let sType = params.top()
  let typeData = getCustomDataByType(sType)

  let parsedData = {}
  foreach (idx, block in typeData)
    foreach (key, val in block)
      parsedData[key] <- params[idx]

  return parsedData
}

let getSessionData = @(sType, pushContextId) sType == PSN_SESSION_TYPE.SKIRMISH
  ? {
      playerSessions = [{
        supportedPlatforms = ["PS4", "PS5"]
        maxPlayers = ::SessionLobby.getMaxMembersCount()
        maxSpectators = 50 //default value by PSN
        joinDisabled = !::SessionLobby.getPublicParam("allowJIP", true) && ::SessionLobby.isRoomInSession //todo update during battle - by allowJip && isInSession
        member = {
          players = [{
            accountId = "me"
            platform = "me"
            pushContexts = [{ pushContextId = pushContextId }]
          }]
        }
        localizedSessionName = {
          defaultLanguage = "en-US"
          localizedText = getLocalizedTextInfo(::SessionLobby.getMissionNameLocIdsArray())
        }
        joinableUserType = "NO_ONE"
        invitableUserType = "LEADER"
        exclusiveLeaderPrivileges = [
          "KICK"
          "UPDATE_JOINABLE_USER_TYPE"
          "UPDATE_INVITABLE_USER_TYPE"
        ]
        swapSupported = !::SessionLobby.isSpectatorSelectLocked
        customData1 = encodeDataToBase64Like(getCustomDataByType(PSN_SESSION_TYPE.SKIRMISH))
        /*customData1 = base64.encodeJson({
          roomId = ::SessionLobby.roomId,
          inviterUid = ::my_user_id_str,
          inviterName = ::my_user_name
          password = ::SessionLobby.password
          key = PSN_SESSION_TYPE.SKIRMISH
        })?.result ?? ""*/
      }]
    }
  : sType == PSN_SESSION_TYPE.SQUAD
  ? {
      playerSessions = [{
        supportedPlatforms = ["PS4", "PS5"]
        maxPlayers = ::g_squad_manager.getMaxSquadSize()
        maxSpectators = 0
        joinDisabled = false
        member = {
          players = [{
            accountId = "me"
            platform = "me"
            pushContexts = [{ pushContextId = pushContextId }]
          }]
        }
        localizedSessionName = {
          defaultLanguage = "en-US"
          localizedText = getLocalizedTextInfo(["ps4/session/squad"])
        }
        joinableUserType = "NO_ONE"
        invitableUserType = "LEADER"
        exclusiveLeaderPrivileges = [
          "KICK"
          "UPDATE_JOINABLE_USER_TYPE"
          "UPDATE_INVITABLE_USER_TYPE"
        ]
        swapSupported = false
        customData1 = encodeDataToBase64Like(getCustomDataByType(PSN_SESSION_TYPE.SQUAD))
      }]
    }
  : {}

let getSessionJoinData = @(pushContextId, isSpectator = false) {
  [isSpectator? "spectators" : "players"] = [{
    accountId = "me"
    platform = "me"
    pushContexts = [{ pushContextId = pushContextId }]
  }]
}

let create = function(sType, saveSessionIdCb) {
  let pushContextId = psnNotify.createPushContext()
  let sessionData = getSessionData(sType, pushContextId)
  pendingSessions.mutate(@(v) v[sType] <- copy(sessionData))

  psnsm.create(
    pendingSessions.value[sType],
    ::Callback(function(r, err) {
      let sessionId = r?.playerSessions[0].sessionId
      saveSessionIdCb(sessionId, err)

      if (!err && !isEmpty(sessionId)) {
        dumpSessionData(sessionId, sType, pushContextId, pendingSessions.value[sType])
      }

      pendingSessions.mutate(@(v) delete v[sType])
    }, this)
  )
}

let destroy = function(sType) {
  //Delete all sessions for [sType], anyway, there must be only one
  foreach (sessionId, info in createdSessionData.value)
    if (!isEmpty(sessionId) && info.sType == sType) {
      let sId = sessionId
      psnsm.destroy(
        sId,
        ::Callback(function(r, err) {
          createdSessionData.mutate(@(v) delete v[sId])
        }, this)
      )
    }
}

let update = function(sessionId, sType) {
  let existSessionInfo = createdSessionData.value?[sessionId]
  let sessionData = getSessionData(sType, existSessionInfo?.pushContextId)
  psnsm.updateInfo(
    sessionId,
    existSessionInfo?.data.playerSessions[0],
    sessionData.playerSessions[0],
    ::Callback(function(r, err) {
      createdSessionData.mutate(@(v) v[sessionId].data = copy(sessionData))
    }, this)
  )
}

let join = function(sessionId, isSpectator, onFinishCb) {
  let pushContextId = psnNotify.createPushContext()
  let sessionData = getSessionJoinData(pushContextId, isSpectator)
  if (isSpectator)
    psnsm.joinAsSpectator(sessionId, sessionData, pushContextId, onFinishCb)
  else
    psnsm.joinAsPlayer(sessionId, sessionData, pushContextId, onFinishCb)
}

let postponeInvite = @(params) postponedInvitations.mutate(@(v) v.append(params))

let afterAcceptInviteCb = function(sessionId, pushContextId, r, err) {
  if (err) {
    ::dagor.debug($"[PSGI] accepted PSN invite, error {err}")
    return
  }

  psnsm.list([sessionId], ::Callback(function(r, err) {
    foreach (sessionData in (r?.playerSessions ?? [])) {
      if (sessionData.sessionId != sessionId)
        continue

      let parsedData = decodeBase64LikeToArray(sessionData?.customData1 ?? "")
      if (!parsedData.len())
        continue

      switch (parsedData.sType) {
        case PSN_SESSION_TYPE.SKIRMISH:
          dumpSessionData(sessionId, parsedData.sType, pushContextId, copy(sessionData))
          let contact = ::getContact(parsedData.inviterUid)
          ::g_invites.addSessionRoomInvite(parsedData.roomId, parsedData.inviterUid, contact.name, parsedData?.password ?? "").accept()
          break
        case PSN_SESSION_TYPE.SQUAD:
          dumpSessionData(sessionId, parsedData.sType, pushContextId, copy(sessionData))
          ::g_invites.addInviteToSquad(parsedData.squadId, parsedData.leaderId).checkAutoAcceptInvite()
          break
      }
    }
  }))
}

let proceedInvite = function(p) {
  let sessionId = p?.sessionId ?? ""

  let isInPsnSession = sessionId in createdSessionData.value

  if (u.isEmpty(sessionId) || isInPsnSession)
    return // Most-likely we are joining from PSN Overlay

  if (!::g_login.isLoggedIn() || ::is_in_loading_screen()) {
    ::dagor.debug("[PSGI:PI] delaying PSN invite until logged in and loaded")
    postponeInvite(p)
    return
  }

  if (isInPsnSession) {
    //There is no deactivation, so just do nothing
    ::dagor.debug("[PSGI:PI] stale PSN invite: already joined")
    return
  }

  if (!::isInMenu()) {
    ::dagor.debug("[PSGI:PI] delaying PSN invite until in menu")
    postponeInvite(p)
    ::get_cur_gui_scene().performDelayed(this, function() {
      ::showInfoMsgBox(::loc("msgbox/add_to_squad_after_fight"), "add_to_squad_after_fight")
    })
    return
  }

  join(
    sessionId,
    p?.isSpectator ?? false,
    afterAcceptInviteCb
  )
}

addListenersWithoutEnv({
  SquadStatusChanged = function(p) {
    switch (::g_squad_manager.state) {
      case squadState.IN_SQUAD:
        if (PSN_SESSION_TYPE.SQUAD in pendingSessions.value)
          break

        let sessionId = ::g_squad_manager.getPsnSessionId()
        let isLeader = ::g_squad_manager.isSquadLeader()
        let isInPsnSession = sessionId in createdSessionData.value
        ::dagor.debug($"[PSSM] onEventSquadStatusChanged {::g_squad_manager.state} for {sessionId}")
        ::dagor.debug($"[PSSM] onEventSquadStatusChanged leader: {isLeader}, psnSessions: {createdSessionData.value.len()}")
        ::dagor.debug($"[PSSM] onEventSquadStatusChanged session bound to PSN: {isInPsnSession}")

        if (!isLeader && !isInPsnSession) // Invite accepted on normal relogin
          join(
            sessionId,
            false,
            function(sId, pushContextId, r, err) {
              if (!err)
                dumpSessionData(sId, PSN_SESSION_TYPE.SQUAD, pushContextId, {})
            }
          )
        else if (isLeader && (isEmpty(sessionId) || isEmpty(createdSessionData.value))) {// Squad implicitly created || Autotransfer on login
          create(
            PSN_SESSION_TYPE.SQUAD,
            function(sId, err) {
              if (!err)
                ::g_squad_manager.setPsnSessionId(sId)
              ::g_squad_manager.processDelayedInvitations()
            }
          )
        }
        break

      case squadState.LEAVING:
        destroy(PSN_SESSION_TYPE.SQUAD)
        break
    }
  }
  SquadSizeChanged = function(p) {
    if (!::g_squad_manager.isSquadLeader())
      return

    let sessionId = ::g_squad_manager.getPsnSessionId()
    if (!isEmpty(sessionId))
      update(sessionId, PSN_SESSION_TYPE.SQUAD)
  }
  SquadLeadershipTransfer = function(p) {
    if (!::g_squad_manager.isSquadLeader())
      return

    let newLeaderData = ::g_squad_manager.getMemberData(p?.uid)
    if (!newLeaderData) {
      ::dagor.debug($"PSN: Session Manager: Didn't found any info for new leader {p?.uid}")
      return
    }

    let sessionId = ::g_squad_manager.getPsnSessionId()
    let contact = ::getContact(p.uid)
    contact.updatePSNIdAndDo(function() {
      psnsm.changeLeadership(
      sessionId,
      contact.psnId,
      newLeaderData.platform.toupper(),
      ::Callback(function(r, err) {
        let existSessionInfo = createdSessionData.value?[sessionId]
        let pushContextId = existSessionInfo?.pushContextId
        let sessionData = getSessionData(PSN_SESSION_TYPE.SQUAD, pushContextId)
        dumpSessionData(sessionId, PSN_SESSION_TYPE.SQUAD, pushContextId, sessionData)
      }, this)
    )})
  }
  GameIntentJoinSession = proceedInvite
  MainMenuReturn = function(p) {
    let invites = copy(postponedInvitations.value)
    postponedInvitations([])

    invites.each(@(p) proceedInvite(p))
  }

  GameIntentLaunchActivity = function(p) { }
  GameIntentLaunchMultiplayerActivity = function(p) { }
})
