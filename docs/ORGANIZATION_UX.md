# Organizations, teams and project inheritance

UX implementation contract for the organization work. This describes intended
behavior, not shipped functionality. Reviewed against the working tree at
`4fa63af` with the organization backend changes still uncommitted.

## Product structure

An organization represents a project or business. It contains teams; each team
has a conversation, one designated head and members with individual roles.
Use **Organization**, **Team**, **Team head** and **Members** consistently in the
management UI. Existing room records remain the team's conversation and retain
their history. Do not create a second team object disconnected from its room.

The human can address any member. **Message team head** is a convenient default,
not a restriction. Selecting it prepares a recipient; sending remains explicit.
Creating an organization, team or member must not start a provider turn.

## Screen structure

```text
Organization: Roundtable app ▾  | Roundtable app / Engineering
                               | Engineering                 Team settings
Overview                       | Head: Morgan     Message team head
Teams                      +   | 3 members · 1 working · 1 needs approval
  Engineering                  |
  Marketing                    | Conversation | Members | Schedules
  Sales                        | Conversation and approval requests
                               |
Schedules                      | Recipients: Morgan, team head
Organization settings          | Write a message…                    Send
```

The organization switcher sits above team navigation on every organization
screen. Its options include **Create organization**. Switching shows the chosen
organization's overview and only its teams; never leave a previous organization's
conversation under a new organization label. URLs identify the selected context
so refresh, links and browser Back preserve it.

The overview shows team name, head, member count and actionable status: working,
queued, needs approval or idle. Status includes text, not color alone. Counts must
come from real state. Clicking a team opens its conversation. An empty overview
says **No teams yet** with **Create a team**.

Team settings hold the brief and project settings. Conversation remains the
primary workspace; member and schedule management are secondary views. Keep
reusable role/model libraries in secondary settings rather than in the primary
navigation. At phone widths, use a labeled **Teams** navigation drawer; retain
the organization and team names in the header and keep Send reachable without
horizontal scrolling.

## Project inheritance

Add an organization project folder and shared brief. The current organization
schema has neither; displaying an inherited label before resolution exists
would misrepresent the effective settings.

| Setting | Default for a new team | Team control |
| --- | --- | --- |
| Project folder | Use the organization's folder | Use organization folder / Use a different folder |
| Organization brief | Included for every team member | Read-only inherited section with a link to organization settings |
| Team brief | Empty additional instructions | Editable; appended to the organization brief |
| Member role | Explicit role selected or written when adding a member | Editable on the member |
| Provider and model | Explicit selection or visibly identified provider default | No silent model changes from organization edits |
| Tool approvals | Existing human-controlled setting | Never inherit unattended approval privileges |

For the folder, display both provenance and the resolved absolute path, for
example **From Roundtable app** followed by the actual path. A customized team
shows **Custom folder** and **Use organization folder**. Restoring inheritance
means future organization changes apply; it is not a one-time copy.

The effective instructions preview has three separately labeled sections:
**Organization brief**, **Team brief**, **Member role**. Brief inheritance is
additive, not replacement. All members in a team use the same effective folder;
do not introduce per-member working directories in this milestone.

An organization can be created without a folder. Before creating an executable
team, require a valid inherited folder or an explicit team folder. Explain the
field as **Where this team's agents work and save files**, including for
marketing and sales teams. Never silently fall back to the home directory.

Organization folder edits show which teams inherit the change and which retain
custom folders. Apply effective-setting changes to new turns; never move a
running turn's working directory. Backend implementation must invalidate or
recreate provider sessions when the next turn uses a different directory.
Surface **Applies to new turns** while work is active.

Migration places existing rooms in **Existing workspace**, preserving every
room's current folder and brief as explicit team settings. Do not infer one
organization folder from rooms that may point to different projects. Adopting
inheritance later is an explicit team setting change.

## Creation and management flows

1. **Create organization:** name, optional project folder, optional shared brief.
   Saving opens its empty overview; nothing starts running.
2. **Create a team:** organization shown explicitly, team name, team purpose and
   resolved folder. A new team may be saved empty as a draft.
3. **Add members:** select saved roles or configure members, with provider/model
   choices visible. Choose one team head. A draft with no head shows
   **Choose a team head**; autonomous delegation is unavailable until assigned.
4. **Change head:** choose a replacement atomically. Never transiently display
   two heads. Removing the head requires choosing a replacement or explicitly
   returning the team to an unconfigured state.
5. **Create schedule:** organization, team, recipient, instruction, frequency and
   timezone remain visible. Show the next occurrence before saving. Saving a
   schedule does not run it immediately.

Validation preserves entered values, identifies the field and explains how to
fix it. Cancel returns to the originating screen and focus returns to the
trigger. Organization names distinguish projects; teams with the same name in
different organizations must remain independently addressable.

## Delegation and control

Recipient selection shows team and organization. Search starts in the current
organization; cross-organization recipients display their full destination.
Ambiguity asks the sender to choose, never selects a matching team silently.
Before sending, show which recipients will start work. Naming a person in prose
and explicitly assigning work need distinguishable interaction semantics.

**Stop current work** stops active and queued work for the selected team.
**Pause schedules** separately prevents future scheduled starts. Each action
names its team and explains its effect; neither silently performs the other.
Cost displays distinguish reported cost, estimates and unavailable data. Missing
cost information must not appear as zero.

## Release acceptance

- Create two organizations, each with an Engineering team. Switching, refreshing
  and browser Back show the correct teams, conversation and project settings.
- Create a team inheriting its organization folder, customize it, then restore
  inheritance. Changing the organization folder affects only inheriting teams
  and new turns, with existing sessions handled correctly.
- Existing teams retain their original folders, briefs, members and history.
- Effective instructions contain organization brief, team brief and member role
  without losing a layer during edits.
- Head selection and replacement remain unambiguous; preparation of a message
  or creation of a team does not execute a provider.
- Schedule creation displays the recipient, timezone and next run. Stop work
  and pause schedules have independently verified effects.
- Keyboard-only operation covers navigation, creation, validation and dialogs.
  Tab and Shift-Tab remain in open dialogs; Escape closes them and restores focus.
- At 1440, 390 and 320 CSS pixels, both themes and 200% zoom preserve readable
  names, visible focus, reachable controls and no horizontal page overflow.
- QA uses an isolated database with provider execution disabled. Browser review
  and the repository's required checks gate implementation sign-off.

The next visible implementation should deliver organization creation, switching
and scoped team navigation. Project inheritance is a separate backend-and-UI
slice with the acceptance cases above; the current name-only organization schema
does not satisfy it. This design does not certify either slice as complete.
