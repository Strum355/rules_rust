# Copyright 2020 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import unittest
import testutil
from bazel_integration_test.test_base import TestBase

class ClippyTest(TestBase):
  def testWorkspace(self):
    testutil.scratch_workspace(self)
    exit_code, stdout, stderr = self.RunBazel(['build', '//...'])
    self.AssertExitCode(exit_code, 0, stderr)

if __name__ == '__main__':
  unittest.main()
