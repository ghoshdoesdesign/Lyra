# "It's Showtime" Shortcut

This iPhone Shortcut is what Siri runs when you say **"Hey Siri, it's showtime"**. It loops: listen → send to Lyra → speak the reply, until Lyra says the conversation is over.

You need the **Server URL** and **API token** printed by `local/start.sh` (laptop) or `deploy/setup.sh` (server).

## Option A: start from ClawPod's Shortcut (fastest)

1. On your iPhone, download [`Activate the Kraken.shortcut`](https://github.com/algal/clawpod/raw/main/Activate%20the%20Kraken.shortcut) from the ClawPod repo and open it to import it.
2. Rename it to **It's Showtime**.
3. Edit it:
   - **Text** action at the top: replace the URL with your Lyra server URL (e.g. `http://my-macbook.local:7001` on your laptop, or `https://203-0-113-7.sslip.io` on a server).
   - **Speak** action: change the greeting to e.g. `Lyra here.`
   - **Get Contents of URL** action: expand it. Under **Headers**, add `Authorization` = `Bearer <your API token>`. In the JSON body, set `speaker` to your name.
4. Do the privacy settings below.

## Option B: build it from scratch

Open **Shortcuts → +**, name it **It's Showtime**, and add these actions:

1. **Text**: your Server URL (e.g. `http://my-macbook.local:7001`)
2. **Set Variable**: name `server`, input = Text
3. **Speak Text**: `Lyra here.` (Wait Until Finished: on)
4. **Repeat** 50 times (a safety cap), containing:
   1. **Ask for Input**: Type **Text**, Prompt `Go on?`
   2. **Get Contents of URL**
      - URL: `server` + `/chat`
      - Method: **POST**
      - Headers: `Authorization` = `Bearer <your API token>`
      - Request Body: **JSON**
        - `text` = *Provided Input*
        - `speaker` = your name (e.g. `Sam`)
   3. **Get Dictionary Value**: key `reply` from *Contents of URL*
   4. **Speak Text**: *Dictionary Value* (Wait Until Finished: on)
   5. **Get Dictionary Value**: key `end_conversation` from *Contents of URL*
   6. **If** *Dictionary Value* **is** `true` → **Stop This Shortcut**

When Siri runs the Shortcut hands-free, "Ask for Input" becomes a spoken prompt, and you answer by voice.

## Privacy and Siri settings

- **Shortcut details (ⓘ) → Privacy:** enable **Allow Running When Locked**. When first asked, allow the Shortcut to access your server URL.
- **Settings → Siri:** enable **Listen for "Hey Siri"** (or "Siri or Hey Siri") and **Allow Siri When Locked**.
- **Settings → [your AirPods]:** make sure Siri is enabled for them.

## Test

1. Run the Shortcut by tapping it in the Shortcuts app. You'll get a text box; type `hello`.
2. Lock the phone, put your AirPods in, and say **"Hey Siri, it's showtime."**
3. Say **"goodbye"** to finish.

**If Siri opens something else** (the Showtime app, a song): rename the Shortcut to something more distinctive, like **Lyra Showtime**, and say that instead.

**Different family members:** each person installs the Shortcut on their own phone with their own `speaker` name, so each gets a separate conversation history.
