# ================================
# Build App image
# ================================
FROM swift:5.6.2-focal as build

# Install OS updates and, if needed, sqlite3
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y sqlite3 libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
    
# Set up a build area
WORKDIR /build

# First just resolve dependencies.
# This creates a cached layer that can be reused
# as long as your Package.swift/Package.resolved
# files do not change.
COPY ./Package.* ./
RUN swift package clean
RUN swift package reset
RUN swift package resolve

# Copy entire repo into container
COPY . .

# Build everything, with optimizations
RUN swift build -c release

# Switch to the staging area
WORKDIR /staging

# Copy main executable to staging area
RUN cp "$(swift build --package-path /build -c release --show-bin-path)/WTNIOServer" ./

# Copy any resouces from the  directory and views directory if the directories exist
# Ensure that by default, neither the directory nor any of its contents are writable.
RUN [ -d /build/Certificates ] && { mv /build/Certificates ./Certificates && chmod -R a-w ./Certificates; } || true
RUN [ -f /build/.env ] && { cp /build/.env ./.env && chmod -R a-w ./.env; } || true

# ================================
# Common setup for run image
# ================================
FROM swift:5.6.2-focal as run-base

# Make sure all system packages are up to date.
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true && \
    apt-get -q update && apt-get -q dist-upgrade -y && rm -r /var/lib/apt/lists/*

# Create a needletail user and group with /base as its home directory
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /base needletail

# Switch to the new home directory
WORKDIR /base

# Copy built executable and any staged resources from builder
COPY --from=build --chown=needletail:needletail /staging /base

# Ensure all further commands run as the needletail user
USER needletail:needletail

# Start the needletail service when the image is run, default to listening on 8888 in production environment
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8888"]

# ================================
# WS run image
# ================================
FROM run-base AS ws

# Let Docker bind to port 8888
EXPOSE 8888

# Use the API executable as the entrypoint
ENTRYPOINT ["./WTNIOServer", "--env", "production"]


