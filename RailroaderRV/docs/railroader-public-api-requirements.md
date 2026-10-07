# Railroader Public API Requirements for RailroaderRV

**Audience:** Railroader maintainers  
**Status:** Static source review and API proposals. Every API name below is illustrative and does not exist in the inspected snapshot unless explicitly identified as existing.

## Executive summary

The shared file RR_API.lua identifies RR.API as Railroader's supported public surface. Its read-only train views already cover most RV train discovery and motion reads. The remaining gaps are a stable locomotive ID in singleplayer, exact locomotive geometry, normalized rider state, authoritative seat changes, and a supported client transition for RV teleports.

The minimal proposed change set is:

1. Complete the existing RR.API.view().id contract with a canonical numeric animal ID in every mode.
2. Add RR.API.locomotiveGeometry(...) and RR.API.riderState(...).
3. Add RR.APIServer.releaseRider(...) and RR.APIServer.assignRider(...) as documented, versioned, server-authoritative companion functions.
4. Add RR.APIClient.applyExternalRideTransition(...) as a documented, versioned client companion function.

No Railroader menu-hook API is needed: the Project Zomboid animal context menu already publishes Events.OnClickedAnimalForContext. RV can use that event and match its clicked animal to RR.API.trains() by the canonical ID. RV-specific permission checks, movement policy, mapping, generation, teleport coordinates, and rollback stay in RV.

## Scope, assumptions, and success conditions

This review covers Railroader integration calls in the RailroaderRV client and server adapters, the shared RR.API contract, Railroader's client/server API adapters, and the official animal context-menu event used by the RV menu. It is a source review only; no game or runtime test was run.

The shared API source says RR.API is the one third-party table whose contract Railroader promises and versions. The current RR.APIClient and RR.APIServer tables expose diagnostics and binding details, but the shared header does not promise them as third-party surfaces. Their proposed functions must therefore be explicitly documented as supported companions and governed by the public version guarantee. Under the current version comments, additive functions and fields do not require a version increment; Railroader should state whether completing the already-guaranteed view.id field is a compatible correction or a versioned semantic change.

The captured reference mod contains RR_API.lua and the client/server adapters. Those Lua sources refer to docs/PUBLIC_API.md, but that Markdown file is absent from this snapshot; this report cites the available API source comments and adapter implementations directly.

### Assumptions and tradeoffs

- The request is limited to the current RailroaderRV integration paths. It does not ask Railroader to expose every internal object, add general-purpose vehicle discovery, or provide unrelated render or line-of-sight hooks.
- RR.API remains read-only. World-authoritative rider changes belong to a documented server companion; local Ride state around RV teleports belongs to a documented client companion.
- Geometry is centralized behind one query so RV does not reproduce Railroader's hull, reach, or seat formulas. The query returns plain data and never exposes a raw animal or train record.
- Existing mode-specific train lists remain the source. A connected client is not promised a global locomotive lookup; the server remains authoritative for the submitted ID.
- Proposed names are examples. The required behavior, data meanings, authority, and failure semantics are the contract.
- Existing RailroaderRV audit documents and past tests are not treated as Railroader public API facts. This report uses the current inspected Railroader and PZ source files.

Success means every RV-to-Railroader integration point is classified below; every proposed API has typed parameters, return shape, units, authority, and expected failure behavior; citations point to exact source lines; and no proposed API is described as already implemented. Static source references do not substitute for runtime or multiplayer validation.

## Coupling inventory

| Side | Current RV coupling | Disposition |
|---|---|---|
| Client: animal identity | Checks IsoAnimal and getAnimalType() == "rr_loco", then reads getAnimalID() | Use the PZ clicked-animal event and match against public view.id after that field is completed. No Railroader type getter is needed. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L112-L132. |
| Client: nearest locomotive and reach | Calls RR.Ride.nearestBoardable(), reads Ride.MOUNT_REACH, and consumes returned record.animal | Use RR.API.trains() plus the new exact locomotive geometry query; select from plain views by hullDistanceTiles and mountReachTiles. Do not add nearestBoardable or expose animal. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L246-L263. |
| Client: Railroader menu hook | Wraps RR.BoardMenu.addForAnimal | Remove the patch and subscribe to PZ Events.OnClickedAnimalForContext. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L349-L359; official lua scripts/client/ISUI/Animal/ISAnimalContextMenu.lua:L1013-L1017, L1235. |
| Client: raw train list and record fields | Enumerates RR.TrainEntity.active and reads record.id / record.animal, with an animal ID fallback | Use RR.API.trains() and canonical view.id. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L399-L413. |
| Client: local Ride transition and mode | Reads RR.Ride.current, calls Ride.dismount(true), writes record._boardPending, checks rr.MPClient, and calls Ride.mountRecord(record, true, seat) | Replace the group with RR.APIClient.applyExternalRideTransition(...). The new function owns local Ride and stale-snapshot state, and suppresses dismount's coordinate side effect. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L416-L464, L562-L573. |
| Client: RV menu and teleport flow | Uses PZ world-menu events and an RV command that sends only locoId | Keep the PZ menu handlers and RV-authoritative command path. The client transition companion brackets the existing teleport/square-refresh order. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L155-L160, L623-L665, L739-L742; RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:L161-L168, L222-L228. |
| Server: list, type, and identity | Chooses RR.ServerTrain.active or RR.TrainEntity.active, checks animal type, and resolves train.id or animal:getAnimalID() | Replace list, type, and ID reads with RR.API.trains() and canonical view.id. The server still validates the requested ID against its own current API view. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L117-L185. |
| Server: pose and motion | Reads animal coordinates, train.pose, drive.v / v / speed, dirX / dirY, getForwardDirection(), and getAnimalSize() | Reuse normalized view pose, direction, and speed for ordinary reads. Geometry and seat queries must consume Railroader-native body/consist state internally; RV does not need a public raw record or size getter. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L198-L264. |
| Server: hull, reach, and seat positions | Calls RR.Body.hullDistance(), RR.Body.seatWorld(), and RR.Ride.MOUNT_REACH; also has local seat-offset and centre-distance fallback calculations | Replace these reads and formulas with RR.API.locomotiveGeometry(). It returns exact hull distance and reach for a point, plus global consist seat positions and passenger seat count. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L266-L301, L354-L379; RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L289-L316. |
| Server: rider identity and available seats | Reads driver/passengers and the SP rider/seat/passenger fields plus RR.Ride.current; counts free passenger seats locally | Use RR.API.riderState() for normalized role/seat and RR.APIServer.assignRider() to select an open passenger seat. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L381-L434, L399-L410. |
| Server: seat mutation and full cleanup | Directly changes driver/passengers, private seat/claim/control fields, player seat flags, and calls RR.ServerTrain.markResync(); EntryExit also directly checks train.driver and passenger mappings | Replace mutations with RR.APIServer.releaseRider() and assignRider(). This includes EntryExit rollback at lines 474-483 and destination selection at lines 637-650, where it checks passenger availability and train.driver. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L436-L591; RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L336-L345, L449-L489, L633-L681. |

## Findings by integration path

### Existing APIs that can replace RV coupling

| RV behavior | Existing surface | Conclusion and evidence |
|---|---|---|
| Find active locomotives and read pose, direction, route, distance, and signed speed | RR.API.trains() and normalized views from RR.API.view() | Reuse these views instead of iterating RR.TrainEntity.active or RR.ServerTrain.active. The view contains the id field, route fields, world pose, and speed; speed is metres per second. The id field is nil for current singleplayer records until the enhancement below. trains() returns one view per locomotive. Evidence: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L261-L315, L553-L582; reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_APIClient.lua:L51-L72; reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_APIServer.lua:L40-L72. |
| Determine whether the bound API is the singleplayer, client, server, or unavailable path | RR.API.available() and RR.API.mode() | Use mode() in place of checking rr.MPClient. The current client adapter classifies a connected client as client; its singleplayer/co-op-host path reports singleplayer. Evidence: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L127-L148; reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_APIClient.lua:L83-L110. |
| Add an RV option to the clicked-animal context menu | Project Zomboid Events.OnClickedAnimalForContext | Subscribe to this existing PZ event and inspect its clicked-animal list. Match an animal's ID to public train views; remove the wrapper around RR.BoardMenu.addForAnimal. The vanilla callback and event registration are at official lua scripts/client/ISUI/Animal/ISAnimalContextMenu.lua:L1013-L1017, L1235; RV's current Railroader wrapper is at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L349-L359. This is static API evidence; event timing has not been runtime-tested. |
| Add RV's nearby-locomotive and in-RV world options | Existing PZ world-menu events | RV already registers its own OnPreFillWorldObjectContextMenu and OnFillWorldObjectContextMenu handlers. Those root options need no Railroader hook. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L623-L665. |
| Send an entry request to the server | Existing RV client command with only the locomotive ID | The client already submits locoId without client coordinates; RV resolves authoritative state on the server. Evidence: RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L155-L160. Keep this authority boundary. |

RR.API.nearestTrain() is not an exact boarding-range replacement. It projects a point onto a route and calculates along-route range using half-length; it does not use the oriented drawn hull distance required by Railroader's boarding rule. The public view's halfLength also contains no hull width or lateral bias. The existing private Ride.nearestBoardable() does use RR.Body.hullDistance() and returns a raw train record, so RV should replace the private call with the proposed geometry query and iterate public train views. Evidence: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L477-L511, L624-L681; reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_Ride.lua:L688-L720; reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_Body.lua:L98-L116, L449-L475.

Do not add a client API that searches all world locomotives. In multiplayer, a client train list is intentionally limited to trains sent to that client; the clicked-animal event supplies the local menu target, and the RV server validates the submitted ID against authoritative current state. A missing distant train view is unknown to that client, not proof that the locomotive does not exist. Evidence: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L553-L560; RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L155-L160; RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L405-L438.

The client event OnRailroaderTrainUpdate is a per-locomotive tick event carrying a reused view, not a lifecycle or relocation callback. The server adapter has no matching event. It is not a substitute for the client transition function below, and no new tick event or ACK event is requested. Evidence: reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_APIClient.lua:L112-L143, L147-L190; reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_APIServer.lua:L29-L72. The shared API also says it is read-only and non-authoritative: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L59-L70. RR.API.bind() is the API's single-slot adapter binding, not a third-party registration extension point: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L90-L123.

### Existing API enhancement: canonical view.id

The existing public view declares id guaranteed, but RR.API.view() currently copies only rec.id. Railroader's singleplayer spawn and adopt records do not set that field, leaving view.id nil there. The server record does set it, and Railroader's MP client comments identify the wire ID as the animal's getAnimalID() value. RV currently falls back to animal:getAnimalID() to identify records and match clicked animals.

Enhance the existing field to be a canonical numeric animal ID for every represented locomotive in every supported mode. Do not add a parallel animalId field. The client and server adapters can resolve the same public ID at the boundary, while views and the per-tick client event continue to expose only normalized data, never the raw animal or train record.

Evidence: reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L266-L287 (guaranteed id, current copy); reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_TrainEntity.lua:L336-L360, L551-L573 (singleplayer records without id); reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_ServerTrain.lua:L1695-L1703, L1760-L1764 (server ID); reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_MPClient.lua:L463-L481 (wire ID equals animal:getAnimalID()); RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L128-L132, L399-L413; RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L126-L135.

### New API proposal: exact locomotive geometry

Suggested function:

RR.API.locomotiveGeometry(locomotiveId: integer, worldX: number, worldY: number)
    -> geometry | nil, reason

The input coordinates are world tile coordinates. On success, return:

    {
      hullDistanceTiles: number,
      mountReachTiles: number,
      passengerSeatCount: integer,
      seatPositions: {
        [0]: { x: number, y: number, z: number }, -- driver
        [1..N]: { x: number, y: number, z: number } -- passengers
      }
    }

hullDistanceTiles is the exact distance from the supplied world point to the locomotive's drawn hull in tiles, and is zero inside or on the hull. mountReachTiles is the same threshold used by Railroader's E interaction and menu rule; callers must not duplicate its current numeric value. seatPositions uses the global consist seat index, with zero for the driver and one through N for passenger seats. Each x/y is a world tile coordinate and z is a world level coordinate; preserve the native numeric seat point. On an inactive locomotive, or on a client where the locomotive is not in that process's current list or has no current streamed pose, return nil with a normal-state reason. For a represented active record, impossible internal geometry state must surface as an exception; do not substitute a centre-radius approximation or hide the fault as nil.

The geometry must use the same native pose rule as the relevant interaction context. Current Ride.hullDistTo() uses the locomotive's lastPose, while RR.API.poseOf() prefers renderPose on a connected client; the geometry implementation must not blindly reuse the view pose and claim exact E-range equivalence. On the authoritative server, use the authoritative body pose. Apply RR.Body.LAT_BIAS through Railroader's hull calculation. Seat positions must use the native seat point and global consist index.

RV uses this one query both to select the nearest eligible locomotive in menus and to validate server-side interaction range. It also needs authoritative target positions for relocation and the current passenger seat count. Railroader should resolve global seat indexes across the consist internally; the server already maps a global seat through Consist.seatUnit() before calling Body.seatWorld().

Evidence: hull and mount-reach reads are RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L246-L263, RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L354-L379, and RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L289-L316. RV's seat position calculation and passenger capacity are RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L266-L301, L399-L410; entry source seat coordinates are used at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L425-L438, and exit target selection at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L633-L675. The official reach is hull-based at reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_Ride.lua:L498-L526; exact hull distance and its units are defined at reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_Body.lua:L98-L116, L361-L366, L459-L475; client interaction pose selection is reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_Ride.lua:L688-L700, while the public view pose preference is reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L174-L179; global seat resolution is reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_ServerTrain.lua:L2511-L2517.

### New API proposal: normalized rider state

Suggested function:

RR.API.riderState(locomotiveId: integer, player: IsoPlayer)
    -> { role, seatIndex } | nil, reason

Return { role = "driver", seatIndex = 0 }, { role = "passenger", seatIndex = 1..N }, or { role = "outside", seatIndex = nil }. Return nil with a normal-state reason only when the locomotive is inactive or not visible in the current process. A client-side snapshot may be useful for presentation, but it must not authorize an RV world mutation; RV's server must use its authoritative result. An impossible internal record state must surface as an exception rather than be converted to nil.

This normalizes the current MP driver/passenger fields and singleplayer Ride state without exposing records. RV needs it to decide whether a moving locomotive may be entered and to retain the original role and seat for generation-failure restoration. Internal RV terminology external maps to public role outside.

Evidence: mode-specific rider inspection is RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L381-L434; entry uses role and seat for movement policy and source coordinates at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L425-L438; generation failure restores the prior seat at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L469-L489.

### New authoritative companion APIs: rider release and assignment

These operations must be documented as supported server-side companions under the public API version guarantee. They are seat lifecycle operations, not permission or relocation operations. RV first applies its own authority, movement, range, mapping, and transaction checks. The Railroader methods then apply the official seat-state transition and synchronization, but do not teleport the player or impose the ordinary board/release movement gates. This distinction preserves RV's existing rule that passengers may enter or leave a moving locomotive.

Suggested functions:

RR.APIServer.releaseRider(locomotiveId: integer, player: IsoPlayer)
    -> { role: "driver" | "passenger", seatIndex: integer } | nil, reason

RR.APIServer.assignRider(
    locomotiveId: integer, player: IsoPlayer,
    role: "driver" | "passenger", seatIndex?: integer
) -> {
    role: "driver" | "passenger",
    seatIndex: integer,
    position: { x: number, y: number, z: number }
} | nil, reason

player is the current server-side IsoPlayer; the functions accept no client coordinates or client-supplied world state. For assignment, role is "driver" or "passenger"; driver seat index is zero. A passenger index may be specified from 1 through N, or omitted so Railroader selects an open passenger seat. A specified occupied seat, a full passenger set, or an inactive locomotive returns nil with a normal-state reason and no partial seat change. Release returns nil with a normal-state reason when the locomotive is inactive or the player is not seated. An impossible internal record state must surface as an exception, not be hidden as nil. Release success returns the removed role and seat index. Assignment success returns the actual selected seat and its authoritative position; x/y are world tile coordinates and z is a world level coordinate, all as numbers preserving the native seat point. Neither operation relocates the player. In singleplayer, the release implementation must suppress the normal Ride step-aside coordinate write so RV remains the only owner of its transition coordinates.

The implementation must own the full Railroader seat lifecycle rather than require RV to copy private field writes. For an MP driver release, RV currently mirrors the native driver-release control and brake semantics by setting `driver = nil`, `throttle = 0`, and `brakeInput = 1` (brake applied); it also clears start/stop latches, cancels an in-progress priming/cranking phase, clears the horn, and removes the driver's command-sequence entry. Passenger release removes that passenger entry. Both clear the rider's seat-name and claim entries, restore movement/shouting/rest/bed-shelter state, and resynchronize the train. Assignment sets the driver/passenger entry, removes the caller's old claim and any claim on the selected seat, updates the seat-name entry, clears the driver's command-sequence entry as applicable, sets the seated player flags, and resynchronizes. Driver assignment also clears RV's copied cruise state (`_cruise = nil` and `_cruiseNotch = nil`). These values document current RV cleanup; the requested API should own Railroader's native lifecycle semantics without freezing private field names as public contract. In singleplayer, use the official Ride lifecycle and keep the persisted rider/seat/passenger state coherent.

Evidence: RV duplicates these writes in RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L465-L490 (assignment bookkeeping and sync), L493-L549 (release and driver/passenger cleanup, including `driver = nil`, `throttle = 0`, and `brakeInput = 1` at L504-L507), and L552-L591 (assignment, including `_cruise = nil` and `_cruiseNotch = nil` at L587-L590). The singleplayer helpers are in RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_Train.lua:L436-L463. RV invokes these operations during entry, rollback, and exit at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L336-L345, L449-L465, L469-L489, and L662-L681. The official packet contains driver/passenger state at reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_ServerTrain.lua:L558-L583; ordinary board and passenger-release speed restrictions are at reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_ServerTrain.lua:L4505 and L4788-L4790.

### New client companion API: external ride transition

RR.API is explicitly read-only, so the local Ride transition cannot be added to it. Add a documented client companion function, for example:

RR.APIClient.applyExternalRideTransition(
    phase: "before" | "after",
    action: "enter" | "exit" | "generation-failed",
    locomotiveId: integer,
    role: "driver" | "passenger" | "outside" | "beside",
    seatIndex?: integer
) -> void

role is required. For enter, it identifies the source state being cleared; for exit, it is the server-selected destination state; for generation-failed, it is the server-restored state. seatIndex is zero for driver, 1 through N for passenger, and nil only for outside or beside. The combinations below define the calls RV needs. The API returns no value. RV calls it with a valid combination; it does not need an unsupported-transition result or fallback.

| Phase and action | Required behavior |
|---|---|
| before enter | Clear the old local Ride binding and suppress any stale-snapshot remount while RV moves the player into its interior. Do not issue a board/release command or change coordinates. |
| after enter | Do not mount a Railroader seat; the player remains in the RV. |
| before exit | Clear any old local Ride binding and arm the internal stale-snapshot gate for a driver/passenger destination seat selected by the server. Do not issue a board/release command or change coordinates. |
| after exit | For driver/passenger, singleplayer restores the server-selected seat and multiplayer waits for the authoritative Railroader snapshot. For outside/beside, do not mount. |
| before generation-failed | Clear the old local Ride binding and arm the internal stale-snapshot gate for the role/seat restored by the server. Do not issue a board/release command or change coordinates. |
| after generation-failed | For driver/passenger, singleplayer restores the server-restored seat and multiplayer waits for the authoritative Railroader snapshot. For outside/beside, do not mount. |

The API owns local Ride state and its stale-snapshot gate, not RV coordinates, generation tokens, or the server transaction. In particular, the current Ride.dismount(true) is not a safe implementation primitive for RV: even with release suppressed, it calls placePlayerBeside() and relocates the player. The API must suppress that side effect so RV's server-supplied destination remains authoritative. The only normal missing-record case is a multiplayer client whose locomotive is not streamed and has no local Ride binding to clear. If singleplayer must restore a seat, a missing required record or seat is not a no-op.

Evidence: RV's current local transition reads Ride.current, calls Ride.dismount(true), and writes _boardPending at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L399-L464; it uses the private mode table and Ride.mountRecord at L562-L573. The final relocation order is prepare, teleport, square refresh, finish at RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_RailroaderContextMenu.lua:L739-L742; the staging and final relocation hooks are RailroaderRV/contents/mods/RailroaderRV/42/media/lua/client/RailroaderRV/GUI/RV_ContextMenu_Relocation.lua:L161-L168, L222-L228. Ride.dismount() calls placePlayerBeside() even when release is skipped: reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_Ride.lua:L922-L984, especially L956-L981. The multiplayer snapshot gate and seat handling are in reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_MPClient.lua:L1738-L1750. RV's transition-token deduplication is already RV-owned and remains there.

### RV responsibilities that do not need Railroader APIs

RV retains player authorization, world mapping, transaction locks, range and movement policy, route generation, boundary handling, teleport coordinates, and rollback. Its entry and exit decisions are made in RailroaderRV/contents/mods/RailroaderRV/42/media/lua/server/RailroaderRV/RVMapping/RV_RailroaderServer_EntryExit.lua:L405-L467 and L587-L687. The existing inactive-mapped exit continues to use its persisted beside position without requiring an active locomotive geometry or seat query; it must not invent a seat. Evidence: the same file at L604-L631. Railroader should not receive RV mapping records, transaction tokens, trusted client coordinates, or requests to choose RV destinations.

The current mode check can use RR.API.mode(). The menu can use the PZ clicked-animal event. Public train views plus the geometry query replace raw record discovery and hull checks. The rider queries and mutations replace only access to Railroader-owned seat state. No line-of-sight query or rendering hook appears in these call paths; if “sight” means line of sight, this review found no API requirement for it.

## Process and authority support that needs explicit documentation

The existing surfaces are loaded by different adapters. reference mods/3774360904/mods/Railroader/42/media/lua/client/Railroader/RR_APIClient.lua binds RR.TrainEntity.active; its co-op-host path reports "singleplayer" (L51-L110). reference mods/3774360904/mods/Railroader/42/media/lua/server/Railroader/RR_APIServer.lua returns unless isServer() is true and isClient() is false, then binds RR.ServerTrain.active (L29-L72). Do not infer that the dedicated-server adapter is also the singleplayer or co-op-host mutation adapter.

Please document the support and authority matrix for each proposed function:

| Process | RR.API train views | riderState authority | APIServer seat mutations | APIClient transition |
|---|---|---|---|---|
| Singleplayer | Existing client adapter reports singleplayer for the TrainEntity read path | Authoritative state for an RV world mutation | The same public methods must be available through a supported singleplayer-authority adapter; the current APIServer guard is not evidence that it loads here | Local client path |
| Connected multiplayer client | Client-visible train snapshot only; distant trains may be absent | Presentation only; not authoritative for RV writes | Must reject/deny invocation | Local transition only; wait for server snapshot |
| Dedicated server | Existing server adapter reports server | Authoritative | Server-authoritative | Not loaded |
| Co-op host | Existing client adapter reports singleplayer and binds TrainEntity records | Use the host's actual authoritative state | Route the same public methods through the host's authoritative adapter and document which adapter supplies them | Local client transition |

RR.API.trains() explicitly describes multiplayer-client lists as only the trains sent to that client, so an empty list is not proof that no locomotive exists globally (reference mods/3774360904/mods/Railroader/42/media/lua/shared/Railroader/RR_API.lua:L553-L560). No new tick event, generic lifecycle callback, ACK, or timeout protocol is needed. PZ's reliable ordered transport and RV's existing transition sequencing are sufficient.

## Validation and unresolved details

The evidence was checked against the current RailroaderRV source, the supplied Railroader API and adapter files, the relevant official Railroader geometry/rider code, and the official PZ animal menu registration. No runtime test was run because the user was unavailable and requested no actual test.

Before implementation, Railroader should confirm the exact supported process matrix for server seat mutations, especially singleplayer and co-op host; confirm the compatibility/version treatment for completing view.id; and document the new companion contracts alongside RR.API. Proposed function names may change, but the normalized data, authority, geometry units, seat indexing, cleanup, and no-relocation semantics above are the requirements.
