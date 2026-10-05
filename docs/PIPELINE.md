# Pipeline routing

Pipeline is another view of the same desk used by Desk and Patching. Changes take effect when a connection gesture or settings action completes, including while audio is running. Changes to devices retain the engine's existing stop/reconfigure behaviour.

![Sources, buses, and output destinations](images/pipeline.png)

## Build a desk

1. Choose **Add → Channel**, then click the source inside its block to select an input device, application, or virtual return. Unassigned and offline sources stay visible.
2. Choose **Add → Bus** for another mix. A block's **… → Settings** menu lets you name a channel/bus and configure its source or mix-minus exclusion. Click the effects area to open the existing insert editor; effects are listed in processing order.
3. Choose **Add → Output Device** to display an available destination. Create new virtual devices in **Virtual Devices** first. Adding an output does not change the monitoring clock or start audio. Use its **… → Use for Monitoring** action explicitly when you want the existing monitor-selection behaviour.
4. Drag a right-hand port to a bus or output. Compatible targets glow green. You can also click an output port, then an input port, or choose **… → Connect to…** using the keyboard. Escape cancels a pending connection. Invalid routes explain the problem and leave routing unchanged.
5. For output cables, choose a mono channel or stereo pair and press **Connect**. New connections start at 0 dB, post-fader where applicable. Direct channel-to-output cables can feed separate recording channels without passing through a bus.

## Inspect and change connections

Click a cable, or choose it from **Connections**, to change level, pre/post-fader selection where applicable, and output channels. Changes stay local to the sheet until **Apply**; **Cancel** leaves the route intact. **Disconnect** removes the cable. Once a cable is selected, closing its sheet and pressing Delete also removes it.

**Undo** and **Redo** in the Pipeline toolbar (⌘Z / ⇧⌘Z) cover routing, channel/bus creation and removal, source configuration, and monitoring selection. They also cover patch-matrix edits. Routing undo preserves unrelated faders and current effects on surviving blocks. Loading another session clears this history. Insert editing retains its existing behaviour and is outside routing undo.

Remove a selected block with Delete or its **…** menu. Removing a channel or bus also removes its routes; undo restores the node and routes. The required Monitor bus cannot be removed. Removing an output disconnects its routes and, if it was the clock output, clears that selection; it does not uninstall or delete any device.

## Read the signal paths

- Channels are on the left, buses follow their connection order when arranged, and destinations are on the right. Output blocks distinguish hardware, Mixing Desk virtual devices, and saved offline destinations.
- Dashed, subdued cables are off; orange exclusion marks show mix-minus. Select a source block to highlight its downstream paths, including contributions excluded through intermediate buses. Exclusion follows source identity: two strips using the same physical device share that identity, and a virtual return associated with an application shares that application's identity.
- The Monitor bus applies audition/solo and Direct Guitar Monitoring to its output. These restrictions do not alter direct recording feeds or downstream bus sends.
- Meters show the live channel/bus signal. They do not imply that every cable is audible: sends can be off, sources can be excluded, and destinations can be offline. The clipping indicator is not a limiter.
- Offline output mappings remain visible. Their levels can still be changed, but reconnect the device to change channel assignments or add new routes to it.

## Arrange and navigate

Drag a block's title to move it. Scroll or drag empty canvas to pan. Pinch to zoom, use the magnifier buttons, or hold Command while scrolling. **Fit All** gives an overview; **Auto Arrange** restores columns based on bus connections. A large graph initially opens at a readable scale, so pan to reach blocks beyond the window.

Block positions and explicitly displayed outputs are included in autosave, exported sessions, and presets. Device reconnection does not rearrange them. Moving blocks, panning, and zooming do not reconfigure audio or reload effects. Older version-1 sessions arrange automatically; malformed presentation metadata is ignored while retaining their audio settings. Zoom and pan are temporary view controls.

The existing limits still apply: no feedback cycles, up to 64 strips/16 buses/512 output routes, mono/stereo channel mapping, and no outgoing bus sends from a bus hosting AU/VST3 effects. See [validation](VALIDATION.md) for automated results and the separate hardware acceptance record.
