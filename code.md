## vscode
```sh
yay -S visual-studio-code-bin claude-code
```

- `~/.config/Code/User/settings.json`
```json
{
    "editor.find.seedSearchStringFromSelection": "never",
    "editor.pasteAs.enabled": false,
    "output.smartScroll.enabled": false,
    "window.menuBarVisibility": "toggle",
    "diffEditor.renderSideBySide": false,
    //"workbench.editor.enablePreview": false,
    // "window.zoomLevel": 1,
    // "workbench.colorTheme": "Monokai",
    "markdown-pdf.displayHeaderFooter": false,
    "claudeCode.preferredLocation": "panel",
    "claudeCode.allowDangerouslySkipPermissions": true
} 
```

## code-oss
```sh
pacman -S code
sudo sed -i 's|node-ovsx-sign|@vscode/vsce-sign|g' /usr/lib/code/out/vs/code/electron-utility/sharedProcess/sharedProcessMain.js
jq '.extensionsGallery={
  serviceUrl:"https://marketplace.visualstudio.com/_apis/public/gallery",
  itemUrl:"https://marketplace.visualstudio.com/items"
}' /usr/lib/code/product.json > /tmp/product.json && sudo mv /tmp/product.json /usr/lib/code/product.json
```

## disabling find for file tree 
https://stackoverflow.com/a/74726732

