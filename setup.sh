#!/bin/bash
# Setup Script
# ============
# Generates test databases for the HE benchmarks

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_BASE_DIR="$SCRIPT_DIR/databases"

# Database configurations
DIMENSIONS=(16 128 512)
ELEMENT_COUNT=10000

echo "============================================="
echo "Database Setup"
echo "============================================="
echo

# Ensure HE tools are built
echo "Checking HE tools..."
pushd "$SCRIPT_DIR/swift-homomorphic-encryption" > /dev/null
if [ ! -f "$(swift build -c release --show-bin-path)/PNNSGenerateDatabase" ]; then
    echo "Building swift-homomorphic-encryption tools..."
    swift build -c release
fi
HE_BIN_PATH=$(swift build -c release --show-bin-path)
popd > /dev/null
echo "  HE tools path: $HE_BIN_PATH"
echo

# Create database directory
mkdir -p "$DB_BASE_DIR"

# Generate databases for all dimensions
echo "Generating databases for dimensions: ${DIMENSIONS[*]}"
echo "Each database will have $ELEMENT_COUNT elements"
echo

for dim in "${DIMENSIONS[@]}"; do
    DB_DIR="$DB_BASE_DIR/dim${dim}_vec${ELEMENT_COUNT}"
    mkdir -p "$DB_DIR"

    echo "Configuration: ${dim}D vectors, ${ELEMENT_COUNT} rows"
    echo "  Directory: $DB_DIR"

    # Skip if already exists
    if [ -f "$DB_DIR/database.binpb" ]; then
        SIZE=$(du -h "$DB_DIR/database.binpb" | cut -f1)
        echo "  Already exists ($SIZE), skipping..."
        echo
        continue
    fi

    # Generate raw database
    echo "  1/3 Generating raw database..."
    "$HE_BIN_PATH/PNNSGenerateDatabase" \
        --output-database "$DB_DIR/raw_database.txtpb" \
        --vector-dimension "$dim" \
        --row-count "$ELEMENT_COUNT" \
        --metadata-size 8 \
        --vector-type random

    # Calculate baby step and giant step for this dimension
    if [ "$dim" -eq 16 ]; then
        babyStep=4
        giantStep=4
    elif [ "$dim" -eq 128 ]; then
        babyStep=12
        giantStep=11
    elif [ "$dim" -eq 512 ]; then
        babyStep=23
        giantStep=22
    else
        babyStep=$(echo "sqrt($dim)" | bc)
        giantStep=$babyStep
        while [ $((babyStep * giantStep)) -lt "$dim" ]; do
            babyStep=$((babyStep + 1))
        done
    fi

    # Create config file for PNNSProcessDatabase
    echo "  2/3 Creating processing config..."
    cat > "$DB_DIR/config.json" <<EOF
{
    "batchSize" : 1,
    "databasePacking" : {
        "diagonal" : {
            "babyStepGiantStep" : {
                "babyStep" : $babyStep,
                "giantStep" : $giantStep,
                "vectorDimension" : $dim
            }
        }
    },
    "distanceMetric" : {
        "cosineSimilarity" : { }
    },
    "extraPlaintextModuli" : [ ],
    "inputDatabase" : "$DB_DIR/raw_database.txtpb",
    "outputDatabase" : "$DB_DIR/database.binpb",
    "outputServerConfig" : "$DB_DIR/server_config.txtpb",
    "queryPacking" : {
        "denseRow" : { }
    },
    "rlweParameters" : "n_4096_logq_27_28_28_logt_17",
    "trialDistanceTolerance" : 0.01,
    "trials" : 1
}
EOF

    # Process database
    echo "  3/3 Processing with HE parameters..."
    "$HE_BIN_PATH/PNNSProcessDatabase" "$DB_DIR/config.json"

    echo "  Done!"
    echo
done

echo "============================================="
echo "Setup complete! Generated databases:"
echo "============================================="
for dim in "${DIMENSIONS[@]}"; do
    DB_PATH="$DB_BASE_DIR/dim${dim}_vec${ELEMENT_COUNT}/database.binpb"
    if [ -f "$DB_PATH" ]; then
        SIZE=$(du -h "$DB_PATH" | cut -f1)
        echo "  - ${dim}D x ${ELEMENT_COUNT} vectors: $SIZE"
    fi
done
echo
echo "Run benchmarks with: ./benchmark.sh"
