#!/usr/bin/env node
const fs = require('fs');
const { printSchema, buildClientSchema } = require('graphql');

const jsonPath = process.argv[2];
const outPath = process.argv[3];
if (!jsonPath || !outPath) {
  console.error('usage: json_to_sdl.js <schema.json> <schema.graphqls>');
  process.exit(1);
}
const raw = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const schema = buildClientSchema(raw.data);
fs.writeFileSync(outPath, printSchema(schema));
console.log('wrote', outPath);
