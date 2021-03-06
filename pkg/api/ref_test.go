/*
Copyright 2014 Google Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package api

import (
	"reflect"
	"testing"

	"github.com/GoogleCloudPlatform/kubernetes/pkg/runtime"
)

type FakeAPIObject struct{}

func (*FakeAPIObject) IsAnAPIObject() {}

func TestGetReference(t *testing.T) {
	table := map[string]struct {
		obj       runtime.Object
		ref       *ObjectReference
		shouldErr bool
	}{
		"pod": {
			obj: &Pod{
				ObjectMeta: ObjectMeta{
					Name:            "foo",
					UID:             "bar",
					ResourceVersion: "42",
					SelfLink:        "/api/v1beta1/pods/foo",
				},
			},
			ref: &ObjectReference{
				Kind:            "Pod",
				APIVersion:      "v1beta1",
				Name:            "foo",
				UID:             "bar",
				ResourceVersion: "42",
			},
		},
		"serviceList": {
			obj: &ServiceList{
				ListMeta: ListMeta{
					ResourceVersion: "42",
					SelfLink:        "/api/v1beta2/services",
				},
			},
			ref: &ObjectReference{
				Kind:            "ServiceList",
				APIVersion:      "v1beta2",
				ResourceVersion: "42",
			},
		},
		"badSelfLink": {
			obj: &ServiceList{
				ListMeta: ListMeta{
					ResourceVersion: "42",
					SelfLink:        "v1beta2/services",
				},
			},
			shouldErr: true,
		},
		"error": {
			obj:       &FakeAPIObject{},
			ref:       nil,
			shouldErr: true,
		},
		"errorNil": {
			obj:       nil,
			ref:       nil,
			shouldErr: true,
		},
	}

	for name, item := range table {
		ref, err := GetReference(item.obj)
		if e, a := item.shouldErr, (err != nil); e != a {
			t.Errorf("%v: expected %v, got %v", name, e, a)
			continue
		}
		if e, a := item.ref, ref; !reflect.DeepEqual(e, a) {
			t.Errorf("%v: expected %#v, got %#v", name, e, a)
		}
	}
}
