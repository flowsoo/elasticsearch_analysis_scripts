#!/usr/bin/env bash

# ============================================================
# Elasticsearch TLS Certificate Inventory
#
# Usage:
#
#   ./cert-inventory.sh
#
# Configure the two folders and three passwords below.
#
# IMPORTANT:
#   This script only READS certificate files.
#   It does not modify Elasticsearch or any certificate.
#
# ============================================================

set -u
set -o pipefail

# ============================================================
# CONFIGURATION
# ============================================================

# Folders to scan recursively
FOLDER1="/etc/elasticsearch"
FOLDER2="/etc/elasticsearch/certs"

# ------------------------------------------------------------
# Elasticsearch secure-keystore passwords
# ------------------------------------------------------------

# xpack.security.http.ssl.keystore.secure_password
HTTP_P12_PASSWORD=""

# xpack.security.transport.ssl.keystore.secure_password
TRANSPORT_KEYSTORE_PASSWORD=""

# xpack.security.transport.ssl.truststore.secure_password
TRANSPORT_TRUSTSTORE_PASSWORD=""

# ============================================================
# END CONFIGURATION
# ============================================================


REPORT="elasticsearch-cert-inventory-$(date +%Y%m%d-%H%M%S).txt"

exec > >(tee "$REPORT") 2>&1


# ============================================================
# REQUIREMENTS
# ============================================================

echo "============================================================"
echo " Elasticsearch TLS Certificate Inventory"
echo "============================================================"
echo
echo "Generated : $(date)"
echo "Folder 1  : $FOLDER1"
echo "Folder 2  : $FOLDER2"
echo

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is not installed."
    exit 1
fi

if ! command -v keytool >/dev/null 2>&1; then
    echo "ERROR: keytool is not installed."
    exit 1
fi

for DIR in "$FOLDER1" "$FOLDER2"; do
    if [[ ! -d "$DIR" ]]; then
        echo "ERROR: Directory does not exist:"
        echo "  $DIR"
        exit 1
    fi
done


# ============================================================
# UTILITY FUNCTIONS
# ============================================================

separator()
{
    echo
    echo "------------------------------------------------------------"
}


# ============================================================
# INSPECT X509 CERTIFICATE
# ============================================================

inspect_x509()
{
    local FILE="$1"

    separator
    echo "FILE:"
    echo "  $FILE"

    if ! openssl x509 -in "$FILE" -noout >/dev/null 2>&1; then
        echo
        echo "TYPE:"
        echo "  Not a directly readable X.509 certificate"
        return
    fi

    echo
    echo "TYPE:"
    echo "  X.509 certificate"

    echo
    echo "SUBJECT:"
    openssl x509 -in "$FILE" -noout -subject 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "ISSUER:"
    openssl x509 -in "$FILE" -noout -issuer 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "SERIAL:"
    openssl x509 -in "$FILE" -noout -serial 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "VALIDITY:"
    openssl x509 -in "$FILE" -noout \
        -startdate \
        -enddate 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "SHA256 FINGERPRINT:"
    openssl x509 -in "$FILE" -noout \
        -fingerprint -sha256 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "SUBJECT ALTERNATIVE NAMES:"

    openssl x509 -in "$FILE" \
        -noout \
        -ext subjectAltName 2>/dev/null \
        | sed 's/^/  /'

    echo
    echo "KEY USAGE / EXTENDED KEY USAGE:"

    openssl x509 -in "$FILE" \
        -text \
        -noout 2>/dev/null \
        | grep -A4 -E \
          "X509v3 Key Usage:|X509v3 Extended Key Usage:" \
        | sed 's/^/  /'

    echo
    echo "BASIC CONSTRAINTS:"

    openssl x509 -in "$FILE" \
        -text \
        -noout 2>/dev/null \
        | grep -A3 "X509v3 Basic Constraints:" \
        | sed 's/^/  /'

    echo
    echo "CA CERTIFICATE:"

    local CA_FLAG

    CA_FLAG=$(openssl x509 \
        -in "$FILE" \
        -text \
        -noout 2>/dev/null \
        | grep -A1 "X509v3 Basic Constraints:" \
        | grep -i "CA:TRUE" || true)

    if [[ -n "$CA_FLAG" ]]; then
        echo "  YES"
    else
        echo "  NO"
    fi
}


# ============================================================
# INSPECT PRIVATE KEY
# ============================================================

inspect_key()
{
    local FILE="$1"

    separator
    echo "FILE:"
    echo "  $FILE"

    echo
    echo "TYPE:"
    echo "  Private key"

    if openssl pkey \
        -in "$FILE" \
        -noout >/dev/null 2>&1; then

        echo
        echo "STATUS:"
        echo "  Valid/readable"

        echo
        echo "KEY TYPE:"

        openssl pkey \
            -in "$FILE" \
            -text \
            -noout 2>/dev/null \
            | head -5 \
            | sed 's/^/  /'

    else

        echo
        echo "STATUS:"
        echo "  Encrypted or unable to read"

    fi
}


# ============================================================
# INSPECT PKCS#12
# ============================================================

inspect_p12()
{
    local FILE="$1"
    local PASSWORD="$2"
    local ROLE="$3"

    separator
    echo "FILE:"
    echo "  $FILE"

    echo
    echo "TYPE:"
    echo "  PKCS#12 / PFX"

    echo
    echo "ROLE BEING TESTED:"
    echo "  $ROLE"

    echo
    echo "PASSWORD:"
    if [[ -n "$PASSWORD" ]]; then
        echo "  Supplied"
    else
        echo "  NOT supplied"
    fi

    if [[ -z "$PASSWORD" ]]; then
        echo
        echo "STATUS:"
        echo "  Cannot inspect password-protected PKCS#12 without password."
        return
    fi

    # --------------------------------------------------------
    # keytool inventory
    # --------------------------------------------------------

    local INFO

    INFO=$(keytool \
        -list \
        -v \
        -storetype PKCS12 \
        -keystore "$FILE" \
        -storepass "$PASSWORD" \
        2>&1)

    if echo "$INFO" | grep -qiE \
        "PrivateKeyEntry|trustedCertEntry|Certificate chain length"; then

        echo
        echo "KEYSTORE CONTENTS:"

        echo "$INFO" |
            grep -E \
            "Alias name:|Entry type:|Certificate chain length:|Owner:|Issuer:|Valid from:|SHA256:" |
            sed 's/^/  /'

    else

        echo
        echo "STATUS:"
        echo "  ERROR: Unable to open PKCS#12 with supplied password."

        echo
        echo "KEYTOOL RESPONSE:"
        echo "$INFO" |
            tail -10 |
            sed 's/^/  /'

        return
    fi


    # --------------------------------------------------------
    # Determine private key
    # --------------------------------------------------------

    echo
    echo "PRIVATE KEY ENTRY:"

    if echo "$INFO" | grep -qi "PrivateKeyEntry"; then
        echo "  YES"
    else
        echo "  NO"
    fi


    # --------------------------------------------------------
    # Extract certificate(s)
    # --------------------------------------------------------

    echo
    echo "CERTIFICATE DETAILS:"

    local CERTDATA

    CERTDATA=$(openssl pkcs12 \
        -in "$FILE" \
        -nokeys \
        -passin "pass:$PASSWORD" \
        2>/dev/null)

    if [[ -z "$CERTDATA" ]]; then

        echo "  Unable to extract certificates."

    else

        local CERT_INDEX=0
        local TEMP_CERT=""

        while read -r LINE; do

            if [[ "$LINE" == "-----BEGIN CERTIFICATE-----" ]]; then

                CERT_INDEX=$((CERT_INDEX + 1))
                TEMP_CERT=$(mktemp)

            fi

            if [[ -n "$TEMP_CERT" ]]; then
                echo "$LINE" >> "$TEMP_CERT"
            fi

            if [[ "$LINE" == "-----END CERTIFICATE-----" ]]; then

                echo
                echo "  CERTIFICATE #$CERT_INDEX"

                echo
                echo "    SUBJECT:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -noout \
                    -subject 2>/dev/null |
                    sed 's/^/      /'

                echo
                echo "    ISSUER:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -noout \
                    -issuer 2>/dev/null |
                    sed 's/^/      /'

                echo
                echo "    SERIAL:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -noout \
                    -serial 2>/dev/null |
                    sed 's/^/      /'

                echo
                echo "    VALIDITY:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -noout \
                    -startdate \
                    -enddate 2>/dev/null |
                    sed 's/^/      /'

                echo
                echo "    SAN:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -noout \
                    -ext subjectAltName 2>/dev/null |
                    sed 's/^/      /'

                echo
                echo "    BASIC CONSTRAINTS:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -text \
                    -noout 2>/dev/null |
                    grep -A3 \
                    "X509v3 Basic Constraints:" |
                    sed 's/^/      /'

                echo
                echo "    KEY USAGE:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -text \
                    -noout 2>/dev/null |
                    grep -A4 -E \
                    "X509v3 Key Usage:|X509v3 Extended Key Usage:" |
                    sed 's/^/      /'

                echo
                echo "    SHA256:"
                openssl x509 \
                    -in "$TEMP_CERT" \
                    -noout \
                    -fingerprint -sha256 2>/dev/null |
                    sed 's/^/      /'

                rm -f "$TEMP_CERT"
                TEMP_CERT=""
            fi

        done <<< "$CERTDATA"

    fi
}


# ============================================================
# INSPECT JKS
# ============================================================

inspect_jks()
{
    local FILE="$1"
    local PASSWORD="$2"

    separator
    echo "FILE:"
    echo "  $FILE"

    echo
    echo "TYPE:"
    echo "  Java KeyStore"

    if [[ -z "$PASSWORD" ]]; then
        echo
        echo "STATUS:"
        echo "  No password supplied."
        return
    fi

    local INFO

    INFO=$(keytool \
        -list \
        -v \
        -keystore "$FILE" \
        -storepass "$PASSWORD" \
        2>&1)

    if echo "$INFO" | grep -qiE \
        "PrivateKeyEntry|trustedCertEntry"; then

        echo
        echo "CONTENTS:"

        echo "$INFO" |
            grep -E \
            "Alias name:|Entry type:|Certificate chain length:|Owner:|Issuer:|Valid from:|SHA256:" |
            sed 's/^/  /'

    else

        echo
        echo "STATUS:"
        echo "  Unable to open JKS."

    fi
}


# ============================================================
# PROCESS FILE
# ============================================================

process_file()
{
    local FILE="$1"

    case "${FILE,,}" in

        *.p12|*.pfx)

            BASENAME=$(basename "$FILE")

            # Select password based on filename.
            if [[ "$BASENAME" == "http_node.p12" ]]; then

                inspect_p12 \
                    "$FILE" \
                    "$HTTP_P12_PASSWORD" \
                    "HTTP SSL keystore"

            elif [[ "$BASENAME" == "node.p12" ]]; then

                # Inspect using transport keystore password
                inspect_p12 \
                    "$FILE" \
                    "$TRANSPORT_KEYSTORE_PASSWORD" \
                    "TRANSPORT SSL keystore"

                # Inspect same file as transport truststore
                inspect_p12 \
                    "$FILE" \
                    "$TRANSPORT_TRUSTSTORE_PASSWORD" \
                    "TRANSPORT SSL truststore"

            else

                # Unknown P12 - try transport keystore password
                inspect_p12 \
                    "$FILE" \
                    "$TRANSPORT_KEYSTORE_PASSWORD" \
                    "UNKNOWN PKCS#12"

            fi
            ;;


        *.crt|*.cer)

            inspect_x509 "$FILE"
            ;;


        *.pem)

            # PEM certificate?
            if openssl x509 \
                -in "$FILE" \
                -noout >/dev/null 2>&1; then

                inspect_x509 "$FILE"

            # PEM private key?
            elif openssl pkey \
                -in "$FILE" \
                -noout >/dev/null 2>&1; then

                inspect_key "$FILE"

            else

                separator
                echo "FILE:"
                echo "  $FILE"
                echo
                echo "TYPE:"
                echo "  PEM file - contents not recognized"

            fi
            ;;


        *.key)

            inspect_key "$FILE"
            ;;


        *.jks)

            inspect_jks \
                "$FILE" \
                "$TRANSPORT_KEYSTORE_PASSWORD"
            ;;

    esac
}


# ============================================================
# FIND ALL CERTIFICATE FILES
# ============================================================

echo "SEARCHING..."
echo

mapfile -t FILES < <(
    find "$FOLDER1" "$FOLDER2" \
        -type f \
        \( \
            -iname '*.p12' \
            -o -iname '*.pfx' \
            -o -iname '*.jks' \
            -o -iname '*.crt' \
            -o -iname '*.cer' \
            -o -iname '*.pem' \
            -o -iname '*.key' \
        \) \
        -print0 |
    sort -z |
    tr '\0' '\n'
)

echo "FOUND ${#FILES[@]} certificate/key files."
echo


# ============================================================
# INSPECT EVERYTHING
# ============================================================

for FILE in "${FILES[@]}"; do
    process_file "$FILE"
done


# ============================================================
# SUMMARY
# ============================================================

echo
echo
echo "============================================================"
echo " SUMMARY"
echo "============================================================"
echo

echo "Files found:"
for FILE in "${FILES[@]}"; do
    echo "  $FILE"
done

echo
echo "Total files: ${#FILES[@]}"

echo
echo "Report saved to:"
echo "  $REPORT"

echo
echo "============================================================"
echo " END OF REPORT"
echo "============================================================"
