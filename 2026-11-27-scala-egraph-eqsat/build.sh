#!/usr/bin/env bash
# Compile with scalac (Scala 3) and package a runnable fat jar: saturn.jar
set -euo pipefail
cd "$(dirname "$0")"
SCALAC=${SCALAC:-scalac}
command -v "$SCALAC" >/dev/null || { echo "scalac (Scala 3) not found; set SCALAC=/path/to/scalac or use: scala-cli run src -- demo"; exit 1; }
SCALA_HOME=${SCALA_HOME:-$(cd "$(dirname "$(readlink -f "$(command -v "$SCALAC")")")/.." && pwd)}
rm -rf build && mkdir -p build/classes
"$SCALAC" -deprecation -feature -d build/classes src/*.scala
# bundle the Scala runtime so the jar runs with plain `java -jar`
for j in $(find "$SCALA_HOME" -name 'scala-library-2*.jar' -o -name 'scala3-library_3-*.jar' | grep -v sources); do
  (cd build/classes && jar xf "$j" && rm -rf META-INF)
done
printf 'Main-Class: saturn.Main\n' > build/manifest.txt
jar cfm saturn.jar build/manifest.txt -C build/classes .
echo "built saturn.jar  ->  java -jar saturn.jar demo"
