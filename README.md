# Stratlab packs

The community pack catalog for [Stratlab](https://github.com/TitanJammer/Stratlab). The app's **Packs → Browse**
tab reads `catalog.json` from this repository and installs packs from the files attached to the `packs` release.

## Publishing a pack

1. In Stratlab, open **Packs → Export strats**, pick your strats, give the pack a name, a description and your
   author name, and save the `.stratlab` file.
2. Post that file in the **#share-packs** channel of the Stratlab Discord. Nothing else is needed: the pack's
   name and description travel inside the file.
3. Within about ten minutes the bot reacts with ✅ and replies with what it published, or with ❌ and the reason.

Re-posting a pack you exported before (same pack, new strats or fixes) updates it in place: everyone who
installed it sees **Update** in Browse. Only the Discord account that first posted a pack can update it.
To take a pack down, post `remove <pack name>` in the channel.

Limits: one `.stratlab` per message, up to 25 MB, at most 200 strats, pictures up to 8 MB each. Packs are
checked the same way the app checks an import (only known agents and maps, real pictures, sane steps).

## How it works (all free)

- `.github/workflows/drop.yml` runs `bot\drop.ps1` every ten minutes on GitHub Actions (free for public
  repositories). It reads new messages in the drop channel through the Discord API with a bot token.
- Each valid pack is uploaded as an asset of the rolling **packs** release (so the repository itself stays
  small) and listed in `catalog.json`, which the workflow commits.
- The app fetches `catalog.json` from `raw.githubusercontent.com` and only downloads pack files from this
  repository's release URLs, verifying the SHA-256 recorded in the catalog before it offers the import preview.

### Setting the bot up

1. Create an application at <https://discord.com/developers/applications>, add a **Bot**, and under
   *Privileged Gateway Intents* enable **Message Content Intent** (without it the API hides attachments).
2. Invite the bot to your server with the permissions *View Channel*, *Read Message History*, *Send Messages*,
   *Add Reactions* (OAuth2 → URL Generator → scope `bot`).
3. Copy the bot token and the id of the drop channel (Discord: Developer Mode on, right-click the channel →
   Copy Channel ID), and store them as repository secrets `DISCORD_TOKEN` and `DISCORD_CHANNEL`
   (Settings → Secrets and variables → Actions, or `gh secret set DISCORD_TOKEN`).
4. Run the **Discord pack drop** workflow once from the Actions tab to check the log. From then on it runs
   on its schedule. (GitHub pauses schedules after 60 days without commits; the bot's own commits count.)

### Upvotes

The app's upvote buttons (on marketplace packs, and on the details page of a strat that came from a pack)
post one line each through a Discord **webhook** into a private channel, for example `#votes`:

```
vote {"v":1,"id":"<install id>","k":"pack","p":"<pack id>","u":1}
```

The bot reads that channel too (secret `DISCORD_VOTES` = its channel id), keeps who voted for what in
`bot/votes.json` (one vote per install, `u:0` takes a vote back) and writes the counts into the catalog
(`votes` per pack, `stratVotes` per strat). To set it up: create a private channel, add a webhook to it
(channel settings → Integrations → Webhooks → New Webhook → Copy URL), put that URL in the app's
`version.json` as `"votes"`, and store the channel id as the `DISCORD_VOTES` secret. Only lines that
arrived through a webhook count, so people typing in the channel change nothing.

`catalog.json` can also be edited by hand to remove or reorder packs. Publisher identities are stored only
as the Discord username shown in the app and a hash of the user id used for the ownership check.
