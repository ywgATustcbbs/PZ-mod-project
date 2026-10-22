#version 330

layout (location = 0) in vec4 vertex;
layout (location = 1) in vec4 normal;
layout (location = 2) in vec2 uv;

out vec3 vertColour;
out vec3 vertNormal;
out vec2 texCoords;

uniform mat4 ModelViewProjection;
uniform mat4 transform;
uniform float targetDepth = 0.5;
uniform float DepthBias;

uniform vec2 UVScale;
uniform float HighResDepthMultiplier = 0.0;
uniform float FinalScale = 1.0;

void main()
{
	vec4 position = vec4(vertex.xyz, 1.0);
	vec4 transformedNormal = vec4(normal.xyz, 0.0);

	texCoords = uv.st * UVScale.xy;
	vertNormal = (transform * transformedNormal).xyz;
	vertColour = vec3(1.0);

	vec4 positionScaled = transform * position;
	positionScaled.xyz *= FinalScale;
	vec4 clipPosition = ModelViewProjection * positionScaled;
	vec4 origin = ModelViewProjection * vec4(0.0, 0.0, 0.0, 1.0);
	clipPosition.z += (origin.z - clipPosition.z) * HighResDepthMultiplier;

	float clipDepth = (clipPosition.z + 1.0) / 2.0;
	clipDepth += targetDepth - 0.5;
	clipPosition.z = (clipDepth * 2.0) - 1.0;
	gl_Position = clipPosition;
}
