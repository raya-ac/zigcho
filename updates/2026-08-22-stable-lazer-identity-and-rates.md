# stable plays and custom rates

Stable Relax and Autopilot rows were reaching the lazer API, but i was not marking them as legacy scores. lazer saw `CL+RX` or `CL+AP` without the Stable score id and treated the row like it came from lazer. that is fixed properly now, including the original Stable score id, legacy score value and replay path.

custom DT and NC rates keep their exact `speed_change` all the way into the pinned lazer calculator. 1.10×, 1.25×, 1.75× and 1.90× are covered instead of silently becoming normal 1.50×. the same `1.25×` marker now shows beside the mod on the website, in the in-game announcement and in the Discord score webhook.
