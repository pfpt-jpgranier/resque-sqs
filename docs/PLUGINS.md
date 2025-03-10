Resque Plugins
==============

Resque encourages plugin development. For a list of available plugins,
please see <https://github.com/resque/resque/wiki/plugins>.

The `docs/HOOKS.md` file included with Resque documents the available
hooks you can use to add or change Resque functionality. This document
describes best practice for plugins themselves.


Version
-------

Plugins should declare the major.minor version of Resque they are
known to work with explicitly in their README.

For example, if your plugin depends on features in Resque 2.1, please
list "Depends on Resque 2.1" very prominently near the beginning of
your README.

Because Resque uses [Semantic Versioning][sv], you can safely make the
following assumptions:

* Your plugin will work with 2.2, 2.3, etc - no methods will be
  removed or changed, only added.
* Your plugin might not work with 3.0+, as APIs may change or be
  removed.


Namespace
---------

All plugins should live under the `ResqueSqs::Plugins` module to avoid
clashing with first class Resque constants or other Ruby libraries.

Good:

* ResqueSqs::Plugins::Lock
* ResqueSqs::Plugins::FastRetry

Bad:

* ResqueSqs::Lock
* ResqueQueue


Gem Name
--------

Gem names should be in the format of `resque-FEATURE`, where `FEATURE`
succinctly describes the feature your plugin adds to ResqueSqs.

Good:

* resque-status
* resque-scheduler

Bad:

* multi-queue
* defunkt-resque-lock


Hooks
-----

Job hook names should be namespaced to work properly.

Good:

* before_perform_lock
* around_perform_check_status

Bad:

* before_perform
* on_failure


Lint
----

Plugins should test compliance to this document using the
`ResqueSqs::Plugin.lint` method.

For example:

``` ruby
assert_nothing_raised do
  ResqueSqs::Plugin.lint(ResqueSqs::Plugins::Lock)
end
```

[sv]: http://semver.org/
