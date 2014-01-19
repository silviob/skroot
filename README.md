Skroot 
======
### Leaving process trees no place to hide. ###

OVERVIEW
--------

Skroot brings clarity to UNIX process trees that communicate through files. A typical example of such network would be the build system of any medium to large software project. These projects tend to spawn a large number of processes, running a variety of programs, each of which reading up to hundreds of files, and producing another handful of files as a result.

Skroot instruments all of these processes at runtime with code that records every file access into a single log for the tree. This log can be examined with a text editor, or more likely, using Skroot's log server, an embedded web server which lifts the process and file graph from the log, creating an HTML representation of the graph for easy analysis with a web browser.

There's no limitation on the complexity of processes that can be scrutinized using Skroot. You could run it on a simple process like `echo` or `cat`, or you could run it on a build of the Linux kernel.


USAGE
-----

Using Skroot is very easy. You just need to prepend the `skroot` command to the invocation of the process to be scrutinized. For example, if you would like to run Skroot on a build, you would run:

    skroot make all

Assuming that `make all` is the command line used to start a build. After the build is finished, you will find a file called `skr.oot` left in the current directory, containing entries for events-of-interest for each process spawned during the build. Next, you will run skroot in server mode, pointing it to the newly created file, like this:

    skroot --server skr.oot

Which will run a webserver on port 8000. Once you connect to the server using a web browser, you will see some statistics about the run, as well as links that will take you into a file centric or process centric view of the run.

One typical use of Skroot is to discover all of the dependents for a given source file. Since the file and process graphs connect all input and output files together, Skroot can show all dependent files, not just those that are directly dependent.

For instance, if you need to see all of the executables depending on an include file, you'd navigate to that file using the file centric view, then click on `File Dependents` on the file page, which will bring up a list of all intermediate and final files that directly or indirectly depend on it.

Skroot also serves as a high level profiler by showing how long each process took, and combined with the I/O statistics, it can be very helpful in optimizing the trickiest of processes.


INTERNALS
---------

Skroot uses LD_PRELOAD from the Linux ELF loader to instrument processes with wrappers around libc calls that produce events-of-interest. These events, timestamped and normalized, get logged into the skr.oot file, for later processing. The log format is kept simple and redundant, each entry context-free and trivial to parse, enabling minimal performance impact on the scrutinized process.


LICENSE
-------

Skroot is free software, licensed under the terms of the MIT License.
