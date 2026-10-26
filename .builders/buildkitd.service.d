# Buildkit daemon configuration
# Install: sudo cp buildkitd.service /etc/systemd/system/
#          sudo systemctl enable --now buildkitd

[Service]
Environment="BUILDKIT_STEP_LOG_MAX_SIZE=536870912"
Environment="BUILDKIT_STEP_LOG_MAX_SPEED=104857600"

[Install]
WantedBy=multi-user.target
