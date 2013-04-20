probabilistic-lua
===================

Turning lua into a probabilistic programming language.

This requires a few small changes to the lua debug library to work. Fortunately, the lua interpeter is very lightweight; I've included a version of [LuaJIT](http://luajit.org/) with the necessary modifications.