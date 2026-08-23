# maps, rooms and profiles are finally behaving like one server

uploaded maps keep their own identity now. bss pulls the whole set apart properly, stores the map files, cover and preview, and can repair older uploads from the osz already in storage. it does not try to send my private billion ids upstream anymore. mapped sets sit on the mapper's profile after recent plays, with a preview that stays on the page.

lazer playlist rooms accept the owner id the real client sends when it creates a new item. ranked play has the countdown the pick screen was waiting for, stops it when somebody chooses a card, and picks a real card when the thirty seconds run out instead of leaving both players stuck forever.

online players can see each other properly too. the server still returns the live Stable and lazer set, and zigcho!lazer now copies online friends into the collection its dashboard actually reads instead of only filling the hidden all-users list.

i cleaned the site up at the same time. the nav is grouped and works on small screens, banners no longer fight the avatar for space, and profiles are ordered pinned, top, firsts, recent, mapped sets, then achievements.

this is zigcho!lazer alpha.12. it is the build that stops friends lying about being offline and stops the ranked pick screen hanging forever.
