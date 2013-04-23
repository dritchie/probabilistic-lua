probabilistic-lua
===================

Turning lua into a probabilistic programming language.

This requires a few small changes to the lua debug library to work. Fortunately, the lua interpeter is very lightweight; I've included a version of [LuaJIT](http://luajit.org/) with the necessary modifications.

Make sure that the code is visible via your LUA_PATH environment variable. For example, if you run `luajit` from the repository root, you'll want to add `./?.lua` and `./?/init.lua` in order for `require` to find the `probabilistic` package and its sub-modules.