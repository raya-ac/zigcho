**zigcho update — missing maps cannot run the server out of work anymore**

missing maps still load in the background, but the server now only hydrates four different maps at once. opening the same missing map twice still joins the work already running. opening a fifth different one does not make another thread, another archive download, and another pp job; stable can ask again after one of the four finishes.

this keeps the useful bit of instant map hydration without letting a pile of different leaderboard requests turn into unlimited upstream work. local metrics now count the requests held back by the cap, and the cap itself has allocation-failure coverage.

also fixed the host notes. covers and previews are live now, so they are not listed as pretend future routes anymore.
