# I Talk a Lot

`italkalot` is an LLM poweredAmong Them player.

It  plays from the visual framebuffer and adds social behavior via LLM (OpenAI API currently) during meetings and votes based on LLM's reasoning.

It's a Nim websocket centered commandline and optionally a GUI application.

It localizes itself on the map, navigates to tasks and bodies, handles crewmate, imposter, and ghost roles, and uses LLM chat and vote during "sus" others, perform deduction and vote during meeting.

- Uses ChatGPT AI-assisted chat and vote decisions when available, while falling back to deterministic vote rules when running as a library or when AI is not responding.
- Localizes its camera by matching the visible screen against the known map, with local and broader fallback searches.
- Uses the map walk mask and A* pathfinding to move toward tasks, bodies, fake imposter goals, and its remembered home position.
- Tracks task icons, radar dots, and checkout candidates to decide which tasks still need attention.
- Holds the action button while standing on a task and waits for the task icon to clear before treating the task as complete.
- Returns to its remembered cafeteria home when it has no active tasks or task leads.
- Recognizes when it is a ghost and continues doing incomplete tasks with direct ghost movement.
- Detects the imposter role from the kill icon and tracks whether the kill action is ready.
- As an imposter, moves between fake task locations, flees visible bodies, and kills a lone visible crewmate when the kill is ready.
- Detects dead bodies as a crewmate, moves into report range, reports them, and remembers where the body was found.
- Tracks recently seen player colors so it can name a suspicious player after a body report.
- Reads the voting screen, including player slots, cursor position, votes, chat speakers, and visible chat text.
- Sends short chat messages during meetings, including body locations and sus calls when it has evidence.
- Avoids voting for itself or dead players and votes skip when it has no useful target.
- Provides an optional debug viewer that shows localization, map state, tasks, pathing, role state, votes, chat, and recent intent.
