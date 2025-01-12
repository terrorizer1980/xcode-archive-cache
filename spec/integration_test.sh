#! /bin/bash
set -x
set -o pipefail

check_for_positive_result() {
  if [ $? != 0 ]; then
    echo "\"$1\"" failed
    exit 1
  else
    echo "\"$1\"" succeeded
  fi
}

check_for_negative_result() {
  if [ $? == 0 ]; then
    echo "\"$1\"" failed
    exit 1
  else
    echo "\"$1\"" succeeded
  fi
}

ROOT_PWD=$PWD
TEST_PROJECT_LOCATION="$PWD/fixtures/test_project/Test"
STATIC_LIB_MODULES_PROJECT_LOCATION="$PWD/fixtures/test_project/StaticLibModules"
INTERSECTING_BUILD_GRAPHS_PROJECT_LOCATION="$PWD/fixtures/test_project/IntersectingBuildGraphs"

IOS_DESTINATION="platform=iOS Simulator,name=iPhone 11,OS=latest"
WATCH_DESTINATION="platform=watchOS Simulator,name=Apple Watch Series 5 - 44mm,OS=latest"
TEST_DESTINATION="${IOS_DESTINATION}|${WATCH_DESTINATION}"

CACHE_LOG_FILE="cache.log"
XCODEBUILD_LOG_FILE="xcodebuild.log"
BUILD_CACHE_DIR="build_cache"

set_pwd() {
  cd "$1"
  check_for_positive_result "Change PWD to $1"
}

perform_full_clean() {
  git clean -xdf . && git checkout HEAD -- .
  check_for_positive_result "Full clean"
}

clean_but_leave_build_cache() {
  git clean -xdf -e "$BUILD_CACHE_DIR" . && git checkout HEAD -- .
  check_for_positive_result "Clean leaving build cache"
}

make_filename_list_enumerable() {
  echo "$1" | tr "|" " "
}

install_pods() {
  pod install
  check_for_positive_result "Install pods"
}

inject_cache() {
  bundle exec ruby "$ROOT_PWD/../bin/xcode-archive-cache" inject --destination="$TEST_DESTINATION" --configuration=Debug --storage="$BUILD_CACHE_DIR" --log-level=verbose | tee "$CACHE_LOG_FILE"
  check_for_positive_result "Build and cache dependencies"
}

test_target() {
  xcodebuild -workspace "$WORKSPACE" -scheme "$1" -destination "$IOS_DESTINATION" -derivedDataPath build test | xcpretty | tee "$XCODEBUILD_LOG_FILE"
  check_for_positive_result "Test $1"
}

build_and_test_app() {
  inject_cache
  test_target "$TARGET"
}

perform_app_test() {
  install_pods
  build_and_test_app
}

perform_both_apps_test() {
  perform_app_test
  test_target "Test2"
}

perform_static_dependency_test() {
  install_pods

  cd StaticDependency
  check_for_positive_result "Go to StaticDependency dir"
  inject_cache
  cd -
}

expect_bundles_to_be_rebuilt() {
  BUNDLES=$(make_filename_list_enumerable "$1")
  for BUNDLE_NAME in $BUNDLES; do
    grep -q "Touching $BUNDLE_NAME" "$2"
    check_for_positive_result "Rebuild check for $BUNDLE_NAME"
  done

  NUMBER_OF_REBUILT_BUNDLES=$(grep "Touching" "$2" | wc -l | xargs)
  NUMBER_OF_BUNDLES_EXPECTED_TO_BE_REBUILT=$(echo "$BUNDLES" | wc -w | xargs)
  if [ "$NUMBER_OF_REBUILT_BUNDLES" != "$NUMBER_OF_BUNDLES_EXPECTED_TO_BE_REBUILT" ]; then
    echo "Number of rebuilt bundles is wrong"
    exit 1
  fi
}

expect_bundles_not_to_be_rebuilt() {
  BUNDLES=$(make_filename_list_enumerable "$1")
  for BUNDLE_NAME in $BUNDLES; do
    grep -q "Touching $BUNDLE_NAME" "$2"
    check_for_negative_result "No-extra-rebuild check for $BUNDLE_NAME"
  done
}

expect_libs_to_be_rebuilt() {
  LIBS=$(make_filename_list_enumerable "$1")
  for LIB_NAME in $LIBS; do
    grep -q "Building library $LIB_NAME" "$2"
    check_for_positive_result "Rebuild check for $LIB_NAME"
  done

  NUMBER_OF_REBUILT_LIBS=$(grep "Building\slibrary" "$2" | wc -l | xargs)
  NUMBER_OF_LIBS_EXPECTED_TO_BE_REBUILT=$(echo "$LIBS" | wc -w | xargs)
  if [ "$NUMBER_OF_REBUILT_LIBS" != "$NUMBER_OF_LIBS_EXPECTED_TO_BE_REBUILT" ]; then
    echo "Number of rebuilt libs is wrong"
    exit 1
  fi
}

expect_libs_not_to_be_rebuilt() {
  LIBS=$(make_filename_list_enumerable "$1")
  for LIB_NAME in $LIBS; do
    grep -q "Building library $LIB_NAME" "$2"
    check_for_negative_result "No-extra-rebuild check for $LIB_NAME"
  done
}

expect_no_invalid_dirs_to_be_reported() {
  grep -q "ld: directory not found for option" "$1"
  check_for_negative_result "No invalid directories reported"
}

add_second_app_to_cachefile() {
  mv Cachefile_two_apps Cachefile
}

add_sibling_import() {
  sed -i.bak "s+// to be removed during tests: ++g" StaticDependency/Libraries/MultipleStaticLibraries/LibraryThatUsesSibling/LibraryThatUsesSibling.h
  check_for_positive_result "Add sibling import"
}

update_single_pod() {
  sed -i.bak "s+pod 'SDCAlertView', '= 2.5.3'+pod 'SDCAlertView', '= 2.5.4'+g" Podfile
  check_for_positive_result "Update single pod"
}

remove_sub_dependency_cache() {
  rm -r "$BUILD_CACHE_DIR/lottie-ios"
  check_for_positive_result "Remove Lottie cache"
}

remove_main_dependency_cache() {
  rm -r "$BUILD_CACHE_DIR/Pods-StaticLibModules"
  check_for_positive_result "Remove Pods-StaticLibModules cache"
}

update_static_lib_with_module_and_test() {
  REPLACE_EXPRESSION="s+AnimatedButton+AnimatedButtonChanged+g"
  sed -i.bak "$REPLACE_EXPRESSION" Pods/lottie-ios/lottie-swift/src/Public/iOS/AnimatedButton.swift
  check_for_positive_result "Update Lottie"

  sed -i.bak "$REPLACE_EXPRESSION" StaticLibModules/ClassNameReporter.m
  check_for_positive_result "Update Lottie-dependent code"

  sed -i.bak "$REPLACE_EXPRESSION" StaticLibModulesUITests/StaticLibModulesUITests.swift
  check_for_positive_result "Update Lottie-dependent test"
}

update_framework_dependency_string_and_test() {
  REPLACE_EXPRESSION="s+I'm a framework dependency+XcodeArchiveCache updated me+g"
  sed -i.bak "$REPLACE_EXPRESSION" StaticDependency/Libraries/LibraryWithFrameworkDependency/FrameworkDependency/FrameworkDependency/FrameworkThing.m
  check_for_positive_result "Update FrameworkThing"

  sed -i.bak "$REPLACE_EXPRESSION" TestUITests/TestUITests.swift
  check_for_positive_result "Update test"
}

update_bundled_json_and_test() {
  REPLACE_EXPRESSION="s+cimb+some_random_string+g"
  sed -i.bak "$REPLACE_EXPRESSION" Pods/MidtransKit/MidtransKit/MidtransKit/resources/bin.json
  check_for_positive_result "Update json"

  sed -i.bak "$REPLACE_EXPRESSION" Test/ViewController.swift
  check_for_positive_result "Update view controller"
}

update_another_static_library_string_and_test() {
  REPLACE_EXPRESSION="s+I'm just another static library+XcodeArchiveCache updated me+g"
  sed -i.bak "$REPLACE_EXPRESSION" StaticDependency/Libraries/MultipleStaticLibraries/AnotherStaticDependency/AnotherStaticDependency.m
  check_for_positive_result "Update static dependency"

  sed -i.bak "$REPLACE_EXPRESSION" TestUITests/TestUITests.swift
  check_for_positive_result "Update test"
}

set_pwd "$INTERSECTING_BUILD_GRAPHS_PROJECT_LOCATION"
WORKSPACE="IntersectingBuildGraphs.xcworkspace"
TARGET="IntersectingBuildGraphs"

ALL_LIBS="libKeychainAccess.a|libPods-Dependency.a|libPods-IntersectingBuildGraphs.a|libDependency.a|libnanopb.a|libGoogleDataTransportCCTSupport.a|libGoogleDataTransport.a"

perform_full_clean && perform_app_test
expect_libs_to_be_rebuilt "$ALL_LIBS" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

clean_but_leave_build_cache && perform_app_test
expect_libs_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

set_pwd "$STATIC_LIB_MODULES_PROJECT_LOCATION"
WORKSPACE="StaticLibModules.xcworkspace"
TARGET="StaticLibModules"

ALL_LIBS="liblottie-ios.a|libPods-StaticLibModules.a|libSomethingWithLottie.a"

# expect static lib with module to be properly injected
#
perform_full_clean && perform_app_test
expect_libs_to_be_rebuilt "$ALL_LIBS" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# remove main dependency cache, expecting only the main dependency to be rebuilt
#
clean_but_leave_build_cache && remove_main_dependency_cache && perform_app_test
expect_libs_to_be_rebuilt "libPods-StaticLibModules.a" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# remove sub-dependency cache, expecting everything to be rebuilt
#
clean_but_leave_build_cache && remove_sub_dependency_cache && perform_app_test
expect_libs_to_be_rebuilt "liblottie-ios.a|libPods-StaticLibModules.a" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# expect static lib with module to be properly injected
# when no rebuild is performed
#
clean_but_leave_build_cache && perform_app_test
expect_libs_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# expect static lib with module changes to propagate everywhere
#
clean_but_leave_build_cache && install_pods && update_static_lib_with_module_and_test && build_and_test_app
expect_libs_to_be_rebuilt "liblottie-ios.a|libPods-StaticLibModules.a" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

set_pwd "$TEST_PROJECT_LOCATION"
WORKSPACE="Test.xcworkspace"
TARGET="Test"

ALL_BUNDLES="SDCAutoLayout.framework|RBBAnimation.framework|MRProgress.framework|SDCAlertView.framework|Pods_Test.framework|FrameworkDependency.framework|KeychainAccess.framework|Pods_TestWatch_Extension.framework|MidtransKit.bundle|MidtransCoreKit.framework|MidtransKit.framework|MoPubSDK.framework|MoPubResources.bundle|MoPub_Applovin_Adapters.framework"
ALL_LIBS="libLibraryWithFrameworkDependency.a|libStaticDependency.a|libLibraryThatUsesSibling.a|libAnotherStaticDependency.a"
perform_full_clean && perform_app_test
expect_bundles_to_be_rebuilt "$ALL_BUNDLES" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "$ALL_LIBS" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# add target with shared dependencies to cachefile
# all dependencies are shared so only umbrella Pods framework should be rebuilt
#
clean_but_leave_build_cache && add_second_app_to_cachefile && perform_both_apps_test
expect_bundles_to_be_rebuilt "Pods_Test2.framework" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# add sibling import, expecting changed library to be rebuilt
#
LIBS_EXPECTED_TO_BE_REBUILT="libLibraryThatUsesSibling.a|libStaticDependency.a"
clean_but_leave_build_cache && add_sibling_import && perform_app_test
expect_bundles_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "$LIBS_EXPECTED_TO_BE_REBUILT" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# update single pod, expecting it to be rebuilt
#
clean_but_leave_build_cache && update_single_pod

BUNDLES_EXPECTED_TO_BE_REBUILT="SDCAlertView.framework|Pods_Test.framework"
perform_app_test
expect_bundles_to_be_rebuilt "$BUNDLES_EXPECTED_TO_BE_REBUILT" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# update our own dependency code, expecting changes to propagate to the app
#
clean_but_leave_build_cache && update_framework_dependency_string_and_test

BUNDLES_EXPECTED_TO_BE_REBUILT="FrameworkDependency.framework"
LIBS_EXPECTED_TO_BE_REBUILT="libLibraryWithFrameworkDependency.a|libStaticDependency.a"
perform_app_test
expect_bundles_to_be_rebuilt "$BUNDLES_EXPECTED_TO_BE_REBUILT" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "$LIBS_EXPECTED_TO_BE_REBUILT" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# update bundle content, expecting changes to propagate to the app
#
clean_but_leave_build_cache && install_pods && update_bundled_json_and_test
BUNDLES_EXPECTED_TO_BE_REBUILT="MidtransKit.bundle|MidtransKit.framework|Pods_Test.framework"
build_and_test_app
expect_bundles_to_be_rebuilt "$BUNDLES_EXPECTED_TO_BE_REBUILT" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# ask for StaticDependency rebuild, expecting nothing to be rebuilt
#
clean_but_leave_build_cache
perform_static_dependency_test
expect_bundles_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_libs_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"

# update another static library code, expecting changes to propagate to the app
#
clean_but_leave_build_cache && install_pods && update_another_static_library_string_and_test

LIBS_EXPECTED_TO_BE_REBUILT="libStaticDependency.a|libAnotherStaticDependency.a"
build_and_test_app
expect_bundles_to_be_rebuilt "" "$CACHE_LOG_FILE"
expect_bundles_not_to_be_rebuilt "$ALL_BUNDLES" "$XCODEBUILD_LOG_FILE"
expect_libs_to_be_rebuilt "$LIBS_EXPECTED_TO_BE_REBUILT" "$CACHE_LOG_FILE"
expect_libs_not_to_be_rebuilt "$ALL_LIBS" "$XCODEBUILD_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$CACHE_LOG_FILE"
expect_no_invalid_dirs_to_be_reported "$XCODEBUILD_LOG_FILE"
