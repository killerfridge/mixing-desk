# Pipeline routing

Pipeline is another view of the same desk used by Desk and Patching. Changes take effect when a connection gesture or settings action completes, including while audio is running. Changes to devices retain the engine's existing stop/reconfigure behaviour.

Choose **Light**, **Dark**, or **System** from the appearance icon in the window header or the **Appearance** menu. The choice is saved for the app; System follows macOS appearance.

![Sources, buses, and output destinations](images/pipeline.png)

## Build a desk

1. Choose **Add → Channel**, then click the source inside its block to select an input device, application, or virtual return. Unassigned and offline sources stay visible.
2. Choose **Add → Bus** for another mix. A block's **… → Settings** menu lets you name a channel/bus and configure its source or mix-minus exclusion. Click the effects area to open the existing insert editor; effects are listed in processing order.
3. Choose **Add → Output Device** to display an available destination. Create new virtual devices in **Virtual Devices** first. Adding an output does not change the monitoring clock or start audio. Use its **… → Use for Monitoring** action explicitly when you want the existing monitor-selection behaviour.
4. Drag a right-hand port to a bus or output. Compatible targets glow green. You can also click an output port, then an input port, or choose **… → Connect to…** using the keyboard. Escape cancels a pending connection. Invalid routes explain the problem and leave routing unchanged.
5. For output cables, choose a mono channel or stereo pair and press **Connect**. New connections start at 0 dB, post-fader where applicable. Direct channel-to-output cables can feed separate recording channels without passing through a bus.

## Inspect and change connections

Adjust the **Level** slider on a channel or bus block to change its fader immediately, from −∞ to +12 dB. Double-click the slider to reset it to 0 dB; hold Shift while dragging for one-tenth sensitivity without an initial jump. Click its readout for exact entry, and use the channel Trim readout for input gain. Enter or focus loss commits a valid level; Escape cancels. Invalid/non-finite/out-of-range input leaves audio unchanged. **M** mutes the channel or bus; a channel's **S** solos it in the monitor mix. These controls share the Desk view's settings and are saved with the session. A channel fader affects post-fader paths; pre-fader connections keep their own levels. Adjust individual output feeds through their cables' connection settings.

Click a cable, or choose it from **Connections**, to change level, pre/post-fader selection where applicable, and output channels. Changes stay local to the sheet until **Apply**; **Cancel** leaves the route intact. **Disconnect** removes the cable. Once a cable is selected, closing its sheet and pressing Delete also removes it.

**Undo** and **Redo** in the Pipeline toolbar (⌘Z / ⇧⌘Z) cover routing, channel/bus creation and removal, source configuration, and monitoring selection. They also cover patch-matrix edits. Routing undo preserves unrelated faders and current effects on surviving blocks. Loading another session clears this history. Insert editing retains its existing behaviour and is outside routing undo.

Remove a selected block with Delete or its **…** menu. Removing a channel or bus also removes its routes; undo restores the node and routes. The required Monitor bus cannot be removed. Removing an output disconnects its routes and, if it was the clock output, clears that selection; it does not uninstall or delete any device.

## Read the signal paths

- Channels are on the left, buses follow their connection order when arranged, and destinations are on the right. Output blocks distinguish hardware, Mixing Desk virtual devices, and saved offline destinations.
- Dashed, subdued cables are off; orange exclusion marks show mix-minus. Select a source block to highlight its downstream paths, including contributions excluded through intermediate buses. Exclusion follows source identity: two strips using the same physical device share that identity, and a virtual return associated with an application shares that application's identity.
- The Monitor bus applies audition/solo and Direct Guitar Monitoring to its output. These restrictions do not alter direct recording feeds or downstream bus sends.
- Meters show held dBFS peaks and live levels. Click a meter, or use its accessible Reset meter action, to clear only that owner’s peak and latched overload. Channel meters follow post-fader protection, before pan; bus meters precede final output protection. Amber LIMIT reports successful limiting, separately from red overload warnings. The output indicator names affected physical destinations. These readings do not imply that every cable is audible: sends can be off, sources excluded, and destinations offline.
- **Solo: N · Clear** appears across tabs; **⇧⌘L** or Clear All Solos in the app/menu-bar mixer clears all monitor solos in one update. **Reset All Meters** clears all held peaks and overload latches.
- Channel and final-output sample-peak protection default on, including for existing sessions. The −1 dBFS ceiling, 48-sample lookahead per stage and 100 ms release add 96 samples / 2 ms, retained during bypass. Channel Settings exposes channel bypass; the Desk menu exposes output bypass. This is sample-peak protection, not true-peak mastering protection, and cannot repair input or plugin distortion.
- Offline output mappings remain visible. Their levels can still be changed, but reconnect the device to change channel assignments or add new routes to it.

## Arrange and navigate

Drag a block's title to move it. Scroll or drag empty canvas to pan. Pinch to zoom, use the magnifier buttons, or hold Command while scrolling. **Fit All** gives an overview; **Auto Arrange** restores columns based on bus connections. A large graph initially opens at a readable scale, so pan to reach blocks beyond the window.

Block positions and explicitly displayed outputs are included in autosave, exported sessions, and presets. Device reconnection does not rearrange them. Moving blocks, panning, and zooming do not reconfigure audio or reload effects. Older version-1 sessions arrange automatically; malformed presentation metadata is ignored while retaining their audio settings. Zoom and pan are temporary view controls.

The existing limits still apply: no feedback cycles, up to 64 strips/16 buses/512 output routes, mono/stereo channel mapping, and no outgoing bus sends from a bus hosting AU/VST3 effects. See [validation](VALIDATION.md) for automated results and the separate hardware acceptance record.
