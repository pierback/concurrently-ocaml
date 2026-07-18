"use strict";

const api = require("./npm/lib/api");
const concurrently = api.concurrently;

module.exports = exports = concurrently;
Object.assign(exports, api);
