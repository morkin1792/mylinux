
## nvidia

1. Abrir nvidia-settings como root
2. Navegar até X Server Display Configuration
3. Escolher Advanced
4. Selecionar resolução e framerate
5. Marcar Force Full Composition Pipeline
6. Apertar em Save to X Configuration File
7. Salvar em /etc/X11/xorg.conf.d/nvidia.conf
8. (Para KDE) Ir em Display and Monitor > Compositor. Escolher: Accurate, OpenGL 3.1, Never, Never, Desativar Allow application to block compositing
9. Reiniciar

