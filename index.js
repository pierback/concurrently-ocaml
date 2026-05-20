"use strict";

const api = require("./npm/lib/api");
const concurrently = api.concurrently;

module.exports = exports = concurrently;
exports.default = exports;
Object.assign(exports, api);
