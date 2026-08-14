// Copyright 2021 The gVisor Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package systrap

import (
	"golang.org/x/sys/unix"

	"gvisor.dev/gvisor/pkg/seccomp"
)

func appendSysThreadArchSeccompRules(rules []seccomp.RuleSet) []seccomp.RuleSet {
	// Allow prctl(71, ...) to pass through to the host kernel only when
	// FEAT_FGT is enabled. When FGT is disabled, VBAR_EL0_FGT is never
	// set (stays 0), so letting prctl(71,1) through would enable FGT
	// hardware redirection to address 0, causing an instant user fault.
	if fgtEnabled {
		rules = append(rules, seccomp.RuleSet{
			Rules: seccomp.MakeSyscallRules(map[uintptr]seccomp.SyscallRule{
				unix.SYS_PRCTL: seccomp.PerArg{
					seccomp.EqualTo(71),  // FEAT_FGT option
					seccomp.AnyValue{},   // arg2: 1=enable, 0=disable
				},
			}),
			Action: seccomp.Allow,
		})
	}
	return rules
}
