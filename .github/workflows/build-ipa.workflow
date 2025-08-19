name: Build iSH-AOK IPA

on:
  workflow_dispatch:
    inputs:
      scheme:
        description: "Xcode scheme (try 'iSH' or 'iSH-AOK')"
        required: false
        default: "iSH"
      configuration:
        description: "Build configuration"
        required: false
        default: "Release"
      bundle_id:
        description: "Bundle identifier override (ROOT_BUNDLE_IDENTIFIER)"
        required: false
        default: "com.example.ish-aok"
      development_team:
        description: "Xcode DEVELOPMENT_TEAM (for signed builds)"
        required: false
        default: ""
      sign_export_method:
        description: "Export method for signed build (app-store, ad-hoc, development)"
        required: false
        default: "ad-hoc"

jobs:
  build:
    runs-on: macos-latest

    env:
      SCHEME: ${{ inputs.scheme }}
      CONFIG: ${{ inputs.configuration }}
      ROOT_BUNDLE_IDENTIFIER: ${{ inputs.bundle_id }}
      DEVELOPMENT_TEAM: ${{ inputs.development_team }}
      # If you set signing secrets, this will flip to 'true' below.
      WANT_SIGNED: ${{ secrets.APPLE_CERT_P12 && secrets.APPLE_PROVISIONING_PROFILE ? 'true' : 'false' }}

    steps:
      - name: Checkout (with submodules)
        uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0

      - name: Show Xcode version
        run: xcodebuild -version

      - name: List available Xcode schemes (helpful for debugging)
        run: |
          xcodebuild -list -project "iSH-AOK.xcodeproj" || true

      - name: Install build deps used by iSH build scripts (meson, ninja, libarchive)
        run: |
          python3 -m pip install --upgrade pip
          python3 -m pip install meson ninja
          brew update
          brew install libarchive || true

      - name: Resolve submodules (belt & suspenders)
        run: git submodule update --init --recursive

      - name: Prepare build/output dirs
        run: |
          mkdir -p build_out
          echo "SCHEME=${SCHEME}"
          echo "CONFIG=${CONFIG}"
          echo "ROOT_BUNDLE_IDENTIFIER=${ROOT_BUNDLE_IDENTIFIER}"

      # ---------- ARCHIVE ----------
      - name: Archive (CODE_SIGNING_ALLOWED=NO for unsigned path)
        if: env.WANT_SIGNED == 'false'
        run: |
          xcodebuild \
            -project "iSH-AOK.xcodeproj" \
            -scheme "${SCHEME}" \
            -configuration "${CONFIG}" \
            -archivePath "$PWD/build_out/ish-aok.xcarchive" \
            DEVELOPMENT_TEAM="" \
            PRODUCT_BUNDLE_IDENTIFIER="${ROOT_BUNDLE_IDENTIFIER}" \
            ROOT_BUNDLE_IDENTIFIER="${ROOT_BUNDLE_IDENTIFIER}" \
            CODE_SIGNING_ALLOWED=NO \
            BUILD_LIBRARY_FOR_DISTRIBUTION=NO \
            clean archive | xcpretty && exit ${PIPESTATUS[0]}

      - name: Archive (signed path)
        if: env.WANT_SIGNED == 'true'
        run: |
          xcodebuild \
            -project "iSH-AOK.xcodeproj" \
            -scheme "${SCHEME}" \
            -configuration "${CONFIG}" \
            -archivePath "$PWD/build_out/ish-aok.xcarchive" \
            DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
            PRODUCT_BUNDLE_IDENTIFIER="${ROOT_BUNDLE_IDENTIFIER}" \
            ROOT_BUNDLE_IDENTIFIER="${ROOT_BUNDLE_IDENTIFIER}" \
            CODE_SIGNING_ALLOWED=YES \
            clean archive | xcpretty && exit ${PIPESTATUS[0]}

      # ---------- EXPORT / PACKAGE ----------
      # Unsigned: create Payload zip -> .ipa
      - name: Package unsigned IPA
        if: env.WANT_SIGNED == 'false'
        run: |
          APP_PATH="$PWD/build_out/ish-aok.xcarchive/Products/Applications"
          APP_NAME="$(ls "$APP_PATH" | head -n1)"
          echo "Detected .app: $APP_NAME"
          mkdir -p Payload
          cp -R "$APP_PATH/$APP_NAME" Payload/
          cd Payload
          zip -qry "../build_out/iSH-AOK-unsigned.ipa" .
          cd ..
          echo "IPA at build_out/iSH-AOK-unsigned.ipa"

      # Signed export requires a signing cert + provisioning profile uploaded as secrets
      #   - APPLE_CERT_P12: base64 of your .p12 (Developer/Distribution)
      #   - APPLE_CERT_PASSWORD: password for that .p12
      #   - APPLE_PROVISIONING_PROFILE: base64 of .mobileprovision matching bundle_id
      - name: Install signing assets
        if: env.WANT_SIGNED == 'true'
        env:
          P12_BASE64: ${{ secrets.APPLE_CERT_P12 }}
          P12_PASSWORD: ${{ secrets.APPLE_CERT_PASSWORD }}
          PROFILE_BASE64: ${{ secrets.APPLE_PROVISIONING_PROFILE }}
        run: |
          mkdir -p ~/Library/MobileDevice/Provisioning\ Profiles
          echo "$PROFILE_BASE64" | base64 --decode > ~/Library/MobileDevice/Provisioning\ Profiles/profile.mobileprovision
          echo "$P12_BASE64" | base64 --decode > signing.p12
          security create-keychain -p "temp_password" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "temp_password" build.keychain
          security import signing.p12 -k build.keychain -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "temp_password" build.keychain

      - name: Create ExportOptions.plist (signed export)
        if: env.WANT_SIGNED == 'true'
        run: |
          cat > build_out/ExportOptions.plist <<'PLIST'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>method</key><string>${{ inputs.sign_export_method }}</string>
            <key>signingStyle</key><string>manual</string>
            <key>stripSwiftSymbols</key><true/>
            <key>compileBitcode</key><false/>
            <key>destination</key><string>export</string>
            <key>teamID</key><string>${{ inputs.development_team }}</string>
            <key>manageAppVersionAndBuildNumber</key><false/>
          </dict>
          </plist>
          PLIST

      - name: Export signed IPA
        if: env.WANT_SIGNED == 'true'
        run: |
          xcodebuild \
            -exportArchive \
            -archivePath "$PWD/build_out/ish-aok.xcarchive" \
            -exportPath "$PWD/build_out/export" \
            -exportOptionsPlist "$PWD/build_out/ExportOptions.plist" | xcpretty && exit ${PIPESTATUS[0]}
          mv build_out/export/*.ipa build_out/iSH-AOK-signed.ipa

      # ---------- ARTIFACTS ----------
      - name: Upload IPA artifact
        uses: actions/upload-artifact@v4
        with:
          name: ipa
          path: |
            build_out/*.ipa

      - name: Upload logs (if present)
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: xcode-logs
          path: ~/Library/Logs/DiagnosticReports/*.crash
          if-no-files-found: ignore
          
