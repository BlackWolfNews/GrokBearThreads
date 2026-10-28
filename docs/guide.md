# Using Threadbear

Threadbear is a Mac app for running AI agent threads. It drives the official
Claude Code and Codex command line tools on your own logins. A small program
called the runner keeps every agent going in the background, so quitting or
updating the app never stops a thread. Your threads are also copied to a
Convex deployment of your own, which is how the iPhone app and the website
can follow along.

This guide is for using it. `INSTALL.md` covers setting it up, and `docs/`
has how it all works inside.

## Threads

A thread is one conversation with an agent, working in one folder on your
Mac. You say what you want done, the agent does it (reading files, running
commands, making changes) and replies. You can have as many threads going as
you like, and each one remembers its whole conversation, so you can come
back to it days later and carry on.

## Full access or Ask before edits

Read this before your first thread. Every thread runs in one of two modes,
shown on the composer (the box you type in) and changed by clicking it.

- **Full access** (the default): the agent edits files and runs commands
  without asking. It can do anything your Mac user account can do, in any
  folder, including deleting files. This is how Threadbear is meant to be
  used day to day, and it's fine for a folder you trust it with.
- **Ask before edits**: the agent stops for your OK before it edits a file
  or runs a command. A card shows in the thread with Allow, Always allow and
  Deny. Always allow only lasts for that thread. A Codex thread in this mode
  can read files but not change them unless you agree.

The mode belongs to one thread. A new thread starts on Full access again
unless you pick otherwise, so if you're unsure about a task, switch it to Ask
before edits before you send. Deleting a thread is one thing an agent always
has to ask about, whatever the mode.

## Your first thread

Press ⌘N, or click New thread, type a message and press Return.

New threads start in the `Threadbear` folder in your home folder
(`~/Threadbear`), which setup makes for you. You can pick another folder for
one thread from the composer's + menu, or change the default in Settings
(⌘,).

A safe first message is one that only reads, such as "What's in this
folder?" or "Explain what you can do for me here." When you're ready for it
to make something, try "Make a file called hello.txt that says hi" and watch
it appear in `~/Threadbear`.

Return sends and Shift-Return adds a new line. You can paste or drop images
into the composer. Stop (⌘.) ends a turn that's running.

## What the list tells you

The threads view has two sections. Running holds threads whose agent is
working now. Inbox holds everything else, with the threads that need you at
the top.

At the right of each row:

- **Working**, with a spinner and a timer: the agent is busy.
- **Needs you**, in orange: the agent has asked you something, wants your OK,
  or has finished and said there's something for you to do.
- A blue dot before the title: a reply you haven't read yet.
- A time: the thread is idle. It finished and doesn't need anything. After a
  while Threadbear stops its agent to save memory, and your next message
  starts it again where it left off.
- **Failed**: the last turn ended with an error. Read the thread to see why,
  and send a message to try again.
- **Stopped**: the runner restarted while the thread was busy.
- **Waiting for room**: every login it could use has hit its limit (see
  Accounts below). It carries on by itself when one has room again.

## Hibernate and Archive

To put a thread away for a while, hibernate it (the Thread menu, the ...
menu, or the button that shows when you hover a row). Pick when it should
come back: in an hour, this evening, tomorrow, next Monday or a time of your
own. It leaves the list, its agent stops, and it comes back marked unread
when the time comes. Hibernating threads have their own view (⌘2).

When a thread is done, archive it with ⌘E, or swipe its row left with two
fingers on the trackpad and let go once the space behind it turns blue (a
quick flick works too). The Archive view (⌘3) lists them with a search box,
and Unarchive, or the same swipe there, puts one back. The iPhone app and the
website call the archive the Den.

## Accounts, pools and Usage

Threadbear uses the Claude Code and Codex logins already on your Mac: the
Claude Code login in `~/.claude` and the Codex login in `~/.codex`. It never
reads their passwords or tokens. The account and model a thread runs on are
small menus on the composer. Whatever you picked last is what the next
thread starts on.

Logins are grouped into pools, one for Claude and one for Codex to begin
with (Settings > Pools). A thread in a pool runs on whichever login has the
most room. When the one it's on gets close to its limit, it moves to
another login in the pool with room, and carries on from where it was. When
none has room, the thread waits and carries on by itself once a limit
resets. With only one login, that means it waits for that login's limit to
reset.

Usage, near the bottom of the left-hand rail, shows how much room each login
has left before it hits its limits (for Claude, the 5-hour and weekly ones).
Threadbear learns these numbers from the threads it runs, so a login's bars
fill in once it has run something.

## The prompts macOS shows you

- **Notifications.** The first time the app opens, macOS asks whether
  Threadbear may send notifications. Click Allow. The app then tells you
  when a thread needs you and you aren't looking at it.
- **Folder access.** When an agent reaches into a protected folder, such as
  Desktop, Documents, Downloads or Dropbox, macOS asks whether to allow it.
  Click Allow if you want agents working there, or Don't Allow if not. You
  can change your mind later in System Settings > Privacy & Security >
  Files and Folders. Starting threads in `~/Threadbear` keeps these prompts
  away until you choose a folder that needs them.

## Your phone and a browser

The Threadbear iPhone app shows your threads, lets you answer the ones that
need you, and sends you notifications. It pairs with your Mac by scanning a
QR code. For now that code comes from a command setup printed at the end:

    swift ios/scripts/pair-qr.swift --prod --url <your deployment URL>

Run it from your Threadbear folder, or ask a thread there to run it for you,
and scan the code with the iPhone app. Keep the code to yourself: anyone who
scans it can run your agents. Settings > Unpair this phone on the iPhone
forgets it.

Notifications reach your phone only while you're away from the Mac by
default. Threadbear counts you as at the Mac when the app is open and you've
used the keyboard or mouse in the last two minutes, and as away when the Mac
is asleep. On the iPhone, Settings > Notify me changes it to Always or Never.

Your threads also have a website, on your own Convex deployment. To sign a
browser in, run `npm run web:sign-in` from your Threadbear folder (it opens
Chrome, signed in). Each thread has its own link: Copy web link in a
thread's ... menu on the Mac, or the Copy link button on the website, gives
you one to paste anywhere you're signed in.

## Patches: your own buttons and panels

A patch adds buttons (chips above the composer) and panels (beside the
thread) for the threads in a folder. A button can run a command, like your
tests, or send the agent a message you use a lot. A panel can show a web
page, such as your app running on localhost, or a list.

You don't need to write one yourself. In a thread in that folder, ask
"add a button that runs the tests" or "add a panel showing localhost:3000",
and the agent writes the patch into the folder's `.threadbear/patches/`
(the format is under "Patches" in `docs/protocol.md`, in your Threadbear
folder). It shows up within a few seconds. A patch is code that runs on your
Mac, so keep only the ones you'd be happy to run.

## Changing Threadbear itself

You can change Threadbear by asking a thread to. Start one in your
Threadbear folder (the clone setup ran from) and say what you'd like
different. A thread there gets its own copy of the code to work in, and when
the change is ready and its checks pass, the agent lands it on your `main`
branch.

Updates then arrive by themselves. Within a few minutes of a change landing
on `main`, the runner builds it and switches over without cutting off any
thread that's partway through a turn, and the app builds its new version in
the background. The app swaps in the new version when you next quit it, when
you choose Restart to Update in the Threadbear menu, or by itself when you've
left it alone for a while with nothing typed.

The Updates icon on the left-hand rail shows what's on its way for the app,
the runner and the Claude Code and Codex tools. A grey dot means something
is in progress and will sort itself out, and a coloured dot means it needs
you. Right-click it for a quick Restart to Update.

## Privacy

Your threads are mirrored to a Convex deployment in your own Convex account,
which setup made: the thread list, the text of each message, and one line
for each thing an agent did. Tool output and images stay on your Mac.
Notifications to your phone go through a small relay Mike runs, because
Apple only delivers notifications for his app through his key. The text is
locked with a key only your phone and your deployment have, so the relay
never sees what a notification says.

## Getting help

- Ask a thread. Its agent knows where this guide is and can read it, or
  look at the code and tell you how something works.
- Ask a thread to run `tb status`, which says what the runner is doing:
  its version, the threads that are busy, and any restart or update on the
  way.
- `threadbear` in Terminal opens the app, and quitting it with ⌘Q is always
  safe, since your threads keep running without it. If the app says it
  can't reach the runner, click Start runner.

## The tour

The first time the app opens it shows you round the window, one part at a
time. Help > Take the Tour runs it again.
